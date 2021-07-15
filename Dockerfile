FROM debian:10
RUN apt update && apt install -y \
	build-essential \
	zlib1g-dev \
	uuid-dev \
	libdigest-sha-perl \
	libelf-dev \
	bc \
	bzip2 \
	bison \
	flex \
	git \
	gnupg \
	iasl \
	m4 \
	nasm \
	patch \
	python \
	wget \
	gnat \
	cpio \
	ccache \
	pkg-config \
	cmake \
	libusb-1.0-0-dev \
	autoconf \
	texinfo \
	ncurses-dev \
	doxygen \
	graphviz \
	udev \
	libudev1 \
	libudev-dev \
	automake \
	libtool \
	rsync \
	autoconf-archive \
	libcurl4 \
	libcurl4-openssl-dev \
	binutils-dev


