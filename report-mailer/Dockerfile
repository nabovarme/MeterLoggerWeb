FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .

# Install system dependencies required by WeasyPrint
RUN apt-get update && apt-get install -y \
	libcairo2 \
	libpango-1.0-0 \
	libpangocairo-1.0-0 \
	libpangoft2-1.0-0 \
	libgdk-pixbuf-xlib-2.0-0 \
	libffi8 \
	shared-mime-info \
	fonts-liberation \
	&& rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "send_reports.py"]
