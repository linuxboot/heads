// SPDX-License-Identifier: GPL-2.0-only

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/nvme_ioctl.h>
#include <linux/sed-opal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#if defined(__x86_64__)
#include <sys/io.h>
#endif

#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))

#define OPAL_DISCOVERY_BUFFER_SIZE 2048
#define OPAL_DISCOVERY_HEADER_SIZE 48
#define OPAL_DISCOVERY_COMID 0x0001
#define OPAL_SECURITY_PROTOCOL 0x01
#define OPAL_FEATURE_V100 0x0200
#define OPAL_FEATURE_V200 0x0203
#define OPAL_METHOD_NOT_AUTHORIZED 0x01

#define NVME_ADMIN_SECURITY_RECEIVE 0x82

#define OPAL_S3_APM_PORT 0xb2
#define OPAL_S3_APM_COMMAND 0xee
#define OPAL_S3_SUBCOMMAND_SET_SECRET 0x01
#define OPAL_S3_SUBCOMMAND_CLEAR_SECRET 0x02
#define OPAL_S3_CONTEXT_SIGNATURE 0x3353504fU
#define OPAL_S3_CONTEXT_VERSION 0x0001
#define OPAL_S3_PASSWORD_MAX 32
#define OPAL_S3_PAGE_ATTEMPTS 256

#if defined(HEADS_OPAL_S3_APMC_V1)
#define OPAL_S3_ENABLED true
#else
#define OPAL_S3_ENABLED false
#endif

enum {
	HEADS_OPAL_ERROR = 1,
	HEADS_OPAL_UNSUPPORTED = 2,
	HEADS_OPAL_AUTH_FAILED = 3,
	HEADS_OPAL_S3_PRE_UNLOCK_FAILED = 4,
	HEADS_OPAL_S3_POST_UNLOCK_FAILED = 5,
	HEADS_OPAL_USAGE = 64,
};

struct opal_s3_context {
	uint32_t signature;
	uint16_t version;
	uint16_t size;
	uint8_t bus;
	uint8_t device;
	uint8_t function;
	uint8_t reserved0;
	uint16_t base_comid;
	uint16_t reserved1;
	uint8_t password_length;
	uint8_t reserved2[3];
	uint8_t password[OPAL_S3_PASSWORD_MAX];
} __attribute__((packed));

_Static_assert(sizeof(struct opal_s3_context) == 52,
	       "coreboot OPAL S3 context ABI changed");

struct pci_bdf {
	uint8_t bus;
	uint8_t device;
	uint8_t function;
};

static void secure_clear(void *buffer, size_t length)
{
	volatile uint8_t *cursor = buffer;

	while (length-- > 0)
		*cursor++ = 0;
}

static uint16_t read_be16(const uint8_t *buffer)
{
	return ((uint16_t)buffer[0] << 8) | buffer[1];
}

static uint32_t read_be32(const uint8_t *buffer)
{
	return ((uint32_t)buffer[0] << 24) |
	       ((uint32_t)buffer[1] << 16) |
	       ((uint32_t)buffer[2] << 8) |
	       buffer[3];
}

static bool unsupported_errno(int error)
{
	return error == ENOTTY || error == EOPNOTSUPP;
}

static bool unavailable_errno(int error)
{
	return error == ENOMEDIUM || error == ENODEV || error == ENXIO;
}

static int get_opal_status(int fd, struct opal_status *status)
{
	memset(status, 0, sizeof(*status));
	if (ioctl(fd, IOC_OPAL_GET_STATUS, status) == 0)
		return 0;
	if (unsupported_errno(errno))
		return HEADS_OPAL_UNSUPPORTED;
	return HEADS_OPAL_ERROR;
}

static const char *status_name(const struct opal_status *status)
{
	if (!(status->flags & OPAL_FL_LOCKING_SUPPORTED) ||
	    !(status->flags & OPAL_FL_LOCKING_ENABLED))
		return "disabled";
	if (status->flags & OPAL_FL_LOCKED)
		return "locked";
	return "unlocked";
}

static int status_device(const char *path, bool print_path)
{
	struct opal_status status;
	int fd;
	int rc;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		if (print_path && unavailable_errno(errno))
			return HEADS_OPAL_UNSUPPORTED;
		fprintf(stderr, "%s: open failed: %s\n", path, strerror(errno));
		return HEADS_OPAL_ERROR;
	}

	rc = get_opal_status(fd, &status);
	close(fd);
	if (rc != 0) {
		if (rc != HEADS_OPAL_UNSUPPORTED)
			fprintf(stderr, "%s: OPAL status failed: %s\n", path,
				strerror(errno));
		return rc;
	}

	if (print_path)
		printf("%s %s\n", path, status_name(&status));
	else
		printf("%s\n", status_name(&status));
	return 0;
}

static int scan_devices(void)
{
	glob_t blocks = {0};
	size_t index;
	int glob_rc;
	int rc = 0;

	glob_rc = glob("/sys/class/block/*", 0, NULL, &blocks);
	if (glob_rc == GLOB_NOMATCH)
		return 0;
	if (glob_rc != 0)
		return HEADS_OPAL_ERROR;

	for (index = 0; index < blocks.gl_pathc; index++) {
		const char *name = strrchr(blocks.gl_pathv[index], '/');
		char partition_path[512];
		char device_path[512];
		char resolved[4096];
		int one_rc;

		if (!name || name[1] == '\0')
			continue;
		if (realpath(blocks.gl_pathv[index], resolved) &&
		    strstr(resolved, "/virtual/block/"))
			continue;
		name++;
		if (snprintf(partition_path, sizeof(partition_path), "%s/partition",
			     blocks.gl_pathv[index]) >= (int)sizeof(partition_path)) {
			rc = HEADS_OPAL_ERROR;
			break;
		}
		if (access(partition_path, F_OK) == 0)
			continue;
		if (snprintf(device_path, sizeof(device_path), "/dev/%s", name) >=
		    (int)sizeof(device_path)) {
			rc = HEADS_OPAL_ERROR;
			break;
		}

		one_rc = status_device(device_path, true);
		if (one_rc == HEADS_OPAL_UNSUPPORTED)
			continue;
		if (one_rc != 0) {
			rc = one_rc;
			break;
		}
	}

	globfree(&blocks);
	return rc;
}

static int read_password(uint8_t *password, size_t capacity, size_t *length)
{
	size_t used = 0;
	bool overflow = false;
	uint8_t byte;
	ssize_t got;

	while ((got = read(STDIN_FILENO, &byte, 1)) == 1) {
		if (byte == '\n')
			break;
		if (used >= capacity) {
			overflow = true;
			break;
		}
		password[used++] = byte;
	}
	if (got < 0) {
		fprintf(stderr, "reading password failed: %s\n", strerror(errno));
		return HEADS_OPAL_ERROR;
	}
	if (overflow) {
		fprintf(stderr, "password exceeds %zu bytes\n", capacity);
		return HEADS_OPAL_ERROR;
	}
	if (used == 0) {
		fprintf(stderr, "empty passwords are not accepted\n");
		return HEADS_OPAL_ERROR;
	}

	*length = used;
	return 0;
}

static void fill_lock_request(struct opal_lock_unlock *request,
			      const uint8_t *password, size_t password_length,
			      enum opal_lock_state lock_state)
{
	memset(request, 0, sizeof(*request));
	request->session.who = OPAL_ADMIN1;
	request->session.opal_key.lr = 0;
	request->session.opal_key.key_len = (uint8_t)password_length;
	memcpy(request->session.opal_key.key, password, password_length);
	request->l_state = lock_state;
}

static int parse_pci_component(const char *component, struct pci_bdf *bdf)
{
	unsigned int domain;
	unsigned int bus;
	unsigned int device;
	unsigned int function;
	int consumed = 0;

	if (sscanf(component, "%x:%x:%x.%x%n", &domain, &bus, &device,
		   &function, &consumed) != 4 || component[consumed] != '\0')
		return -1;
	if (domain != 0 || bus > UINT8_MAX || device > 0x1f || function > 7)
		return -1;

	bdf->bus = (uint8_t)bus;
	bdf->device = (uint8_t)device;
	bdf->function = (uint8_t)function;
	return 0;
}

static int device_pci_bdf(int fd, struct pci_bdf *bdf)
{
	struct stat stat_buffer;
	char link_path[128];
	char resolved[4096];
	char path_copy[4096];
	char *component;
	char *saveptr = NULL;
	int found = -1;

	if (fstat(fd, &stat_buffer) != 0 || !S_ISBLK(stat_buffer.st_mode))
		return -1;
	if (snprintf(link_path, sizeof(link_path), "/sys/dev/block/%u:%u/device",
		     major(stat_buffer.st_rdev), minor(stat_buffer.st_rdev)) >=
	    (int)sizeof(link_path))
		return -1;
	if (!realpath(link_path, resolved))
		return -1;

	memcpy(path_copy, resolved, strlen(resolved) + 1);
	for (component = strtok_r(path_copy, "/", &saveptr); component;
	     component = strtok_r(NULL, "/", &saveptr)) {
		struct pci_bdf candidate;

		if (parse_pci_component(component, &candidate) == 0) {
			*bdf = candidate;
			found = 0;
		}
	}
	return found;
}

static int parse_discovery_comid(const uint8_t *buffer, size_t buffer_length,
				 uint16_t *base_comid)
{
	size_t cursor = OPAL_DISCOVERY_HEADER_SIZE;
	uint32_t discovery_length;
	bool found = false;

	if (buffer_length < OPAL_DISCOVERY_HEADER_SIZE)
		return -1;
	discovery_length = read_be32(buffer);
	if (discovery_length < OPAL_DISCOVERY_HEADER_SIZE ||
	    discovery_length > buffer_length)
		return -1;

	while (cursor < discovery_length) {
		uint16_t code;
		uint8_t length;

		if (discovery_length - cursor < 4)
			return -1;
		code = read_be16(buffer + cursor);
		length = buffer[cursor + 3];
		cursor += 4;
		if (length > discovery_length - cursor)
			return -1;

		if ((code == OPAL_FEATURE_V100 || code == OPAL_FEATURE_V200) &&
		    length >= 4) {
			*base_comid = read_be16(buffer + cursor);
			found = true;
		}
		cursor += length;
	}

	return found ? 0 : -1;
}

static int nvme_discovery_comid(int fd, uint16_t *base_comid)
{
	uint8_t buffer[OPAL_DISCOVERY_BUFFER_SIZE] = {0};
	struct nvme_admin_cmd command = {0};

	command.opcode = NVME_ADMIN_SECURITY_RECEIVE;
	command.nsid = 0;
	command.addr = (uintptr_t)buffer;
	command.data_len = sizeof(buffer);
	command.cdw10 = ((uint32_t)OPAL_SECURITY_PROTOCOL << 24) |
			((uint32_t)OPAL_DISCOVERY_COMID << 8);
	command.cdw11 = sizeof(buffer);

	if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &command) != 0)
		return -1;
	return parse_discovery_comid(buffer, sizeof(buffer), base_comid);
}

static int virtual_to_physical(const void *address, uint64_t *physical)
{
	uint64_t entry;
	long page_size = sysconf(_SC_PAGESIZE);
	uintptr_t virtual_address = (uintptr_t)address;
	off_t offset;
	int fd;

	if (page_size <= 0)
		return -1;
	offset = (off_t)((virtual_address / (uintptr_t)page_size) * sizeof(entry));
	fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	if (pread(fd, &entry, sizeof(entry), offset) != (ssize_t)sizeof(entry)) {
		close(fd);
		return -1;
	}
	close(fd);

	if (!(entry & (UINT64_C(1) << 63)))
		return -1;
	entry &= (UINT64_C(1) << 55) - 1;
	if (entry == 0)
		return -1;
	*physical = entry * (uint64_t)page_size +
		    virtual_address % (uintptr_t)page_size;
	return 0;
}

static void *allocate_smi_page(uint64_t *physical, size_t *page_size_out)
{
	void *pages[OPAL_S3_PAGE_ATTEMPTS] = {0};
	long page_size = sysconf(_SC_PAGESIZE);
	void *selected = NULL;
	size_t index;

	if (page_size <= 0)
		return NULL;
	for (index = 0; index < ARRAY_SIZE(pages); index++) {
		pages[index] = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE,
				    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (pages[index] == MAP_FAILED) {
			pages[index] = NULL;
			break;
		}
		memset(pages[index], 0, (size_t)page_size);
		if (virtual_to_physical(pages[index], physical) == 0 &&
		    *physical <= UINT32_MAX &&
		    mlock(pages[index], (size_t)page_size) == 0 &&
		    virtual_to_physical(pages[index], physical) == 0 &&
		    *physical <= UINT32_MAX) {
			selected = pages[index];
			break;
		}
	}

	for (index = 0; index < ARRAY_SIZE(pages); index++) {
		if (!pages[index] || pages[index] == selected)
			continue;
		munmap(pages[index], (size_t)page_size);
	}
	if (selected)
		*page_size_out = (size_t)page_size;
	return selected;
}

#if defined(__x86_64__)
static unsigned long trigger_smi(unsigned long command, unsigned long argument)
{
	unsigned long result = command;

	__asm__ volatile("outb %%al, $0xb2"
			 : "+a"(result)
			 : "b"(argument)
			 : "memory");
	return result;
}
#endif

static int call_s3_service(uint8_t subcommand, unsigned long argument)
{
#if defined(__x86_64__)
	unsigned long command;
	unsigned long result;

	if (ioperm(OPAL_S3_APM_PORT, 1, 1) != 0) {
		fprintf(stderr, "enabling APMC access failed: %s\n", strerror(errno));
		return -1;
	}

	command = ((unsigned long)subcommand << 8) | OPAL_S3_APM_COMMAND;
	result = trigger_smi(command, argument);
	ioperm(OPAL_S3_APM_PORT, 1, 0);
	if (result == command) {
		fprintf(stderr, "coreboot did not handle the OPAL S3 request\n");
		return -1;
	}
	if (result != 0) {
		fprintf(stderr, "coreboot rejected the OPAL S3 request: 0x%lx\n",
			result);
		return -1;
	}
	return 0;
#else
	(void)subcommand;
	(void)argument;
	fprintf(stderr, "OPAL S3 handoff is only supported on x86_64\n");
	return -1;
#endif
}

static int clear_s3_secrets(void)
{
	return call_s3_service(OPAL_S3_SUBCOMMAND_CLEAR_SECRET, 0);
}

static int handoff_s3_secret(const struct pci_bdf *bdf, uint16_t base_comid,
			     const uint8_t *password, size_t password_length)
{
#if defined(__x86_64__)
	struct opal_s3_context *context;
	uint64_t physical = 0;
	size_t page_size = 0;
	int rc;

	context = allocate_smi_page(&physical, &page_size);
	if (!context) {
		fprintf(stderr, "could not allocate a low physical page for OPAL S3 handoff\n");
		return -1;
	}

	context->signature = OPAL_S3_CONTEXT_SIGNATURE;
	context->version = OPAL_S3_CONTEXT_VERSION;
	context->size = sizeof(*context);
	context->bus = bdf->bus;
	context->device = bdf->device;
	context->function = bdf->function;
	context->base_comid = base_comid;
	context->password_length = (uint8_t)password_length;
	memcpy(context->password, password, password_length);

	rc = call_s3_service(OPAL_S3_SUBCOMMAND_SET_SECRET,
			     (unsigned long)physical);

	secure_clear(context, sizeof(*context));
	munlock(context, page_size);
	munmap(context, page_size);
	return rc;
#else
	(void)bdf;
	(void)base_comid;
	(void)password;
	(void)password_length;
	fprintf(stderr, "OPAL S3 handoff is only supported on x86_64\n");
	return -1;
#endif
}

static int change_lock_state(const char *path, bool unlock, bool s3_handoff)
{
	struct opal_lock_unlock request;
	struct pci_bdf bdf = {0};
	uint8_t password[OPAL_KEY_MAX] = {0};
	uint16_t base_comid = 0;
	size_t password_length = 0;
	int fd = -1;
	int ioctl_rc;
	int rc;
	bool s3_clear_failed = false;

	if (mlock(password, sizeof(password)) != 0) {
		fprintf(stderr, "locking password memory failed: %s\n", strerror(errno));
		return HEADS_OPAL_ERROR;
	}
	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "%s: open failed: %s\n", path, strerror(errno));
		rc = HEADS_OPAL_ERROR;
		goto out;
	}

	if (unlock && s3_handoff) {
		if (device_pci_bdf(fd, &bdf) != 0 ||
		    nvme_discovery_comid(fd, &base_comid) != 0) {
			fprintf(stderr, "%s: could not obtain NVMe OPAL S3 metadata\n", path);
			rc = HEADS_OPAL_S3_PRE_UNLOCK_FAILED;
			goto out;
		}
	}

	rc = read_password(password, OPAL_KEY_MAX - 1, &password_length);
	if (rc != 0)
		goto out;
	if (unlock && s3_handoff && password_length > OPAL_S3_PASSWORD_MAX) {
		fprintf(stderr, "coreboot OPAL S3 handoff accepts at most %u bytes\n",
			OPAL_S3_PASSWORD_MAX);
		rc = HEADS_OPAL_S3_PRE_UNLOCK_FAILED;
		goto out;
	}

	if (!unlock && s3_handoff && clear_s3_secrets() != 0)
		s3_clear_failed = true;

	fill_lock_request(&request, password, password_length,
			  unlock ? OPAL_RW : OPAL_LK);
	ioctl_rc = ioctl(fd, IOC_OPAL_LOCK_UNLOCK, &request);
	if (ioctl_rc != 0) {
		if (ioctl_rc == OPAL_METHOD_NOT_AUTHORIZED) {
			fprintf(stderr, "%s: OPAL password was not authorized\n", path);
			rc = HEADS_OPAL_AUTH_FAILED;
		} else if (ioctl_rc < 0) {
			fprintf(stderr, "%s: OPAL %s failed: %s\n", path,
				unlock ? "unlock" : "lock", strerror(errno));
			rc = HEADS_OPAL_ERROR;
		} else {
			fprintf(stderr, "%s: OPAL %s failed with method status 0x%x\n",
				path, unlock ? "unlock" : "lock", ioctl_rc);
			rc = HEADS_OPAL_ERROR;
		}
		goto out_request;
	}
	if (unlock && s3_handoff &&
	    handoff_s3_secret(&bdf, base_comid, password, password_length) != 0) {
		fill_lock_request(&request, password, password_length, OPAL_LK);
		if (ioctl(fd, IOC_OPAL_LOCK_UNLOCK, &request) != 0)
			fprintf(stderr, "%s: rollback lock failed after S3 handoff error\n",
				path);
		if (clear_s3_secrets() != 0)
			fprintf(stderr, "clearing coreboot OPAL S3 secrets failed\n");
		rc = HEADS_OPAL_S3_POST_UNLOCK_FAILED;
		goto out_request;
	}
	rc = s3_clear_failed ? HEADS_OPAL_ERROR : 0;

out_request:
	secure_clear(&request, sizeof(request));
out:
	secure_clear(password, sizeof(password));
	munlock(password, sizeof(password));
	if (fd >= 0)
		close(fd);
	return rc;
}

static void usage(const char *program)
{
	fprintf(stderr,
		"usage: %s scan\n"
		"       %s status DEVICE\n"
		"       %s unlock DEVICE\n"
		"       %s lock DEVICE\n",
		program, program, program, program);
}

int main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "scan") == 0)
		return scan_devices();
	if (argc == 3 && strcmp(argv[1], "status") == 0)
		return status_device(argv[2], false);
	if (argc == 3 && strcmp(argv[1], "unlock") == 0)
		return change_lock_state(argv[2], true, OPAL_S3_ENABLED);
	if (argc == 3 && strcmp(argv[1], "lock") == 0)
		return change_lock_state(argv[2], false, OPAL_S3_ENABLED);

	usage(argv[0]);
	return HEADS_OPAL_USAGE;
}
