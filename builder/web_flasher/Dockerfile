FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Install Nginx + cleanup
RUN apt-get update && \
    apt-get install -y nginx ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Remove default site
RUN rm -rf /var/www/html/*

# Copy your web flasher files
COPY ./builder/web_flasher/site/ /var/www/html/

# Ensure proper permissions
RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
