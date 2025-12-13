import os
import json
from datetime import datetime
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from weasyprint import HTML

# --- Environment variables ---
REPORTS_DIR = '/reports'
SMTP_HOST = os.getenv('SMTP_HOST')
SMTP_PORT = int(os.getenv('SMTP_PORT', 587))
SMTP_USER = os.getenv('SMTP_USER')
SMTP_PASSWORD = os.getenv('SMTP_PASSWORD')
RECIPIENTS = os.getenv('RECIPIENTS', '').split(',')

if not all([SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, RECIPIENTS]):
	raise RuntimeError("SMTP environment variables are not fully set.")

# --- Process JSON reports ---
for filename in os.listdir(REPORTS_DIR):
	if not filename.endswith('.json'):
		continue

	json_path = os.path.join(REPORTS_DIR, filename)
	with open(json_path, 'r') as f:
		report = json.load(f)

	# --- Create HTML report ---
	html_content = f"""
	<h2>Daily Energy Report {report.get('date', 'Unknown')}</h2>
	<h3>System Totals</h3>
	<ul>
	"""
	for item in report.get('system_totals', []):
		html_content += f"<li>{item.get('type', '')}: Total {item.get('total_energy', 0)} kWh, Peak {item.get('peak_effect', 0)} kW</li>"
	html_content += "</ul>"

	html_content += "<h3>Spikes / Anomalies</h3><ul>"
	for item in report.get('spikes', []):
		html_content += f"<li>{item.get('serial', '')}: {item.get('spike_count', 0)} spikes</li>"
	html_content += "</ul>"

	html_content += f"<h3>LLM Summary</h3><p>{report.get('llm_summary', '')}</p>"

	# --- Save PDF using WeasyPrint ---
	pdf_file = os.path.join(REPORTS_DIR, f"report_{report.get('date', 'unknown')}.pdf")
	HTML(string=html_content).write_pdf(pdf_file)

	# --- Send email ---
	msg = MIMEMultipart()
	msg['From'] = SMTP_USER
	msg['To'] = ", ".join(RECIPIENTS)
	msg['Subject'] = f"Daily Energy Report {report.get('date', 'Unknown')}"
	msg.attach(MIMEText(html_content, 'html'))

	try:
		with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
			server.ehlo()
			server.starttls()
			server.ehlo()
			server.login(SMTP_USER, SMTP_PASSWORD)
			server.sendmail(SMTP_USER, RECIPIENTS, msg.as_string())
		print(f"Report sent to: {RECIPIENTS}")
	except Exception as e:
		print(f"Failed to send report: {e}")
