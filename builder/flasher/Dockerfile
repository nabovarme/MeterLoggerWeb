FROM debian:bookworm

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    usbutils \
    make \
    && rm -rf /var/lib/apt/lists/*

# Install esptool with break-system-packages for Debian Bookworm
RUN pip3 install --break-system-packages esptool==4.7.0

# Set working directory
WORKDIR /app

# Copy the Makefile into the image
COPY ./builder/flasher/Makefile .

# Keep container running
CMD ["tail", "-f", "/dev/null"]
