// SPDX-License-Identifier: GPL-2.0-only

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define main heads_opal_program_main
#include "../../util/heads-opal.c"
#undef main

static void test_unlock_request(void)
{
	const uint8_t password[] = "correct horse";
	struct opal_lock_unlock request;

	fill_lock_request(&request, password, sizeof(password) - 1, OPAL_RW);
	assert(request.session.who == OPAL_ADMIN1);
	assert(request.session.sum == 0);
	assert(request.session.opal_key.lr == 0);
	assert(request.session.opal_key.key_len == sizeof(password) - 1);
	assert(memcmp(request.session.opal_key.key, password,
		      sizeof(password) - 1) == 0);
	assert(request.l_state == OPAL_RW);

	fill_lock_request(&request, password, sizeof(password) - 1, OPAL_LK);
	assert(request.l_state == OPAL_LK);
}

static void test_status_names(void)
{
	struct opal_status status = {0};

	assert(strcmp(status_name(&status), "disabled") == 0);
	status.flags = OPAL_FL_LOCKING_SUPPORTED | OPAL_FL_LOCKING_ENABLED |
		       OPAL_FL_LOCKED;
	assert(strcmp(status_name(&status), "locked") == 0);
	status.flags &= ~OPAL_FL_LOCKED;
	assert(strcmp(status_name(&status), "unlocked") == 0);
}

static void test_error_classes(void)
{
	assert(unsupported_errno(ENOTTY));
	assert(unsupported_errno(EOPNOTSUPP));
	assert(!unsupported_errno(EINVAL));
	assert(!unsupported_errno(EIO));
	assert(unavailable_errno(ENOMEDIUM));
	assert(unavailable_errno(ENODEV));
	assert(unavailable_errno(ENXIO));
	assert(!unavailable_errno(EACCES));
}

static void test_discovery_parser(void)
{
	uint8_t discovery[64] = {0};
	uint16_t comid = 0;

	discovery[3] = 56;
	discovery[48] = 0x02;
	discovery[49] = 0x03;
	discovery[51] = 4;
	discovery[52] = 0x12;
	discovery[53] = 0x34;
	assert(parse_discovery_comid(discovery, sizeof(discovery), &comid) == 0);
	assert(comid == 0x1234);

	discovery[51] = 16;
	assert(parse_discovery_comid(discovery, sizeof(discovery), &comid) != 0);
	discovery[51] = 4;
	discovery[3] = 47;
	assert(parse_discovery_comid(discovery, sizeof(discovery), &comid) != 0);
}

static void test_pci_parser(void)
{
	struct pci_bdf bdf = {0};

	assert(parse_pci_component("0000:5d:1f.7", &bdf) == 0);
	assert(bdf.bus == 0x5d);
	assert(bdf.device == 0x1f);
	assert(bdf.function == 7);
	assert(parse_pci_component("0001:00:01.0", &bdf) != 0);
	assert(parse_pci_component("0000:00:20.0", &bdf) != 0);
	assert(parse_pci_component("not-pci", &bdf) != 0);
}

static void test_password_reader(void)
{
	uint8_t password[4] = {0};
	size_t length = 0;
	int input[2];
	int saved_stdin;

	assert(pipe(input) == 0);
	assert(write(input[1], "abc\n", 4) == 4);
	close(input[1]);
	saved_stdin = dup(STDIN_FILENO);
	assert(saved_stdin >= 0);
	assert(dup2(input[0], STDIN_FILENO) == STDIN_FILENO);
	close(input[0]);
	assert(read_password(password, 3, &length) == 0);
	assert(length == 3);
	assert(memcmp(password, "abc", 3) == 0);
	assert(dup2(saved_stdin, STDIN_FILENO) == STDIN_FILENO);
	close(saved_stdin);

	memset(password, 0, sizeof(password));
	length = 0;
	assert(pipe(input) == 0);
	assert(write(input[1], "abcd", 4) == 4);
	close(input[1]);
	saved_stdin = dup(STDIN_FILENO);
	assert(saved_stdin >= 0);
	assert(dup2(input[0], STDIN_FILENO) == STDIN_FILENO);
	close(input[0]);
	assert(read_password(password, 3, &length) == HEADS_OPAL_ERROR);
	assert(dup2(saved_stdin, STDIN_FILENO) == STDIN_FILENO);
	close(saved_stdin);
}

int main(void)
{
	test_unlock_request();
	test_status_names();
	test_error_classes();
	test_discovery_parser();
	test_pci_parser();
	test_password_reader();
	puts("heads-opal C tests: PASS");
	return 0;
}
