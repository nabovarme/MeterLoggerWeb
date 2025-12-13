import os
import mysql.connector
import pandas as pd
import matplotlib.pyplot as plt
import json
import requests
from datetime import datetime, timedelta

# --- Environment variables ---
MYSQL_HOST = os.environ['MYSQL_HOST']
MYSQL_USER = os.environ['MYSQL_USER']
MYSQL_PASSWORD = os.environ['MYSQL_PASSWORD']
MYSQL_DB = os.environ['MYSQL_DB']
HUGGINGFACE_API_KEY = os.environ['HUGGINGFACE_API_KEY']
REPORTS_DIR = '/reports'

# --- Connect to MySQL ---
conn = mysql.connector.connect(
	host=MYSQL_HOST,
	user=MYSQL_USER,
	password=MYSQL_PASSWORD,
	database=MYSQL_DB
)

# --- Fetch data for the previous day ---
yesterday = datetime.now() - timedelta(days=1)
yesterday_unix = int(yesterday.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())

query = f"""
SELECT s.serial, s.unix_time, s.energy, s.effect, s.is_spike, m.type, m.group as group_id, mg.group as group_name
FROM samples s
JOIN meters m ON s.serial = m.serial
JOIN meter_groups mg ON m.group = mg.id
WHERE s.unix_time >= {yesterday_unix} AND m.enabled=1
"""
df = pd.read_sql(query, conn)

# --- Aggregate by type and group ---
agg_system = df.groupby('type').agg(
	total_energy=('energy','sum'),
	peak_effect=('effect','max')
).reset_index()

agg_groups = df.groupby(['group_name','type']).agg(
	total_energy=('energy','sum'),
	peak_effect=('effect','max')
).reset_index()

# --- Plot total system consumption ---
plt.figure(figsize=(10,5))
for t in df['type'].unique():
	subset = df[df['type']==t]
	subset.groupby('unix_time')['energy'].sum().plot(label=t)
plt.xlabel('Time')
plt.ylabel('Energy (kWh)')
plt.title('System Consumption Previous Day')
plt.legend()
plt.tight_layout()
plot_file = os.path.join(REPORTS_DIR, f'system_consumption_{datetime.now().date()}.png')
plt.savefig(plot_file)
plt.close()

# --- Find spikes / anomalies ---
spikes = df[df['is_spike']==1].groupby('serial').size().reset_index(name='spike_count')

# --- Prepare data for LLM ---
summary_data = {
	"date": str(datetime.now().date()),
	"system_totals": agg_system.to_dict(orient='records'),
	"group_totals": agg_groups.to_dict(orient='records'),
	"spikes": spikes.to_dict(orient='records')
}

# --- Hugging Face LLM summary ---
hf_url = "https://api-inference.huggingface.co/models/gpt-4"  # replace with chosen model
headers = {"Authorization": f"Bearer {HUGGINGFACE_API_KEY}"}
prompt = f"Summarize energy data for {summary_data['date']} in plain English:\n{json.dumps(summary_data)}"

response = requests.post(hf_url, headers=headers, json={"inputs": prompt})
hf_output = response.json()
summary_data['llm_summary'] = hf_output[0]['generated_text'] if isinstance(hf_output, list) else "No output"

# --- Save JSON for mailer ---
report_file = os.path.join(REPORTS_DIR, f'report_{datetime.now().date()}.json')
with open(report_file, 'w') as f:
	json.dump(summary_data, f, indent=2)

print(f"Report saved: {report_file}")
