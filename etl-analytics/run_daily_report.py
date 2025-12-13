import os
import pandas as pd
import matplotlib.pyplot as plt
import json
from datetime import datetime, timedelta
from sqlalchemy import create_engine
from huggingface_hub import InferenceClient

# --- Environment variables ---
MYSQL_HOST = os.environ['MYSQL_HOST']
MYSQL_USER = os.environ['MYSQL_USER']
MYSQL_PASSWORD = os.environ['MYSQL_PASSWORD']
MYSQL_DB = os.environ['MYSQL_DB']
HUGGINGFACE_API_KEY = os.environ['HUGGINGFACE_API_KEY']
REPORTS_DIR = '/reports'

BASELINE_YEARS = 1

# --- Time windows ---
today = datetime.now()
yesterday = today - timedelta(days=1)

y_start = int(yesterday.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
y_end = int(yesterday.replace(hour=23, minute=59, second=59, microsecond=0).timestamp())

baseline_start = int((yesterday - timedelta(days=365 * BASELINE_YEARS)).timestamp())
baseline_end = y_end

print(f"[INFO] Yesterday window: {y_start} → {y_end}")
print(f"[INFO] Baseline window: {baseline_start} → {baseline_end}")

# --- Connect to MySQL via SQLAlchemy ---
engine = create_engine(
	f"mysql+mysqlconnector://{MYSQL_USER}:{MYSQL_PASSWORD}@{MYSQL_HOST}/{MYSQL_DB}"
)

# --- Fetch yesterday data ---
query_yesterday = f"""
SELECT s.serial, s.unix_time, s.energy, s.effect, s.is_spike,
	   m.type, mg.group AS group_name
FROM samples s
JOIN meters m ON s.serial = m.serial
LEFT JOIN meter_groups mg ON m.group = mg.id
WHERE s.unix_time BETWEEN {y_start} AND {y_end}
AND m.enabled = 1
"""
df_yesterday = pd.read_sql(query_yesterday, engine)
print(f"[INFO] Yesterday rows: {len(df_yesterday)}")

# --- Fetch baseline data ---
query_baseline = f"""
SELECT s.serial, s.unix_time, s.energy, s.effect,
	   m.type
FROM samples s
JOIN meters m ON s.serial = m.serial
WHERE s.unix_time BETWEEN {baseline_start} AND {baseline_end}
AND m.enabled = 1
"""
df_baseline = pd.read_sql(query_baseline, engine)
print(f"[INFO] Baseline rows: {len(df_baseline)}")

# --- Aggregations ---
agg_yesterday = df_yesterday.groupby('type').agg(
	total_energy=('energy', 'sum'),
	peak_effect=('effect', 'max')
).reset_index()

agg_baseline = df_baseline.groupby('type').agg(
	total_energy=('energy', 'mean'),
	peak_effect=('effect', 'max')
).reset_index()

comparison = agg_yesterday.merge(
	agg_baseline,
	on='type',
	suffixes=('_yesterday', '_baseline'),
	how='left'
)

comparison['energy_change_pct'] = (
	(comparison['total_energy_yesterday'] - comparison['total_energy_baseline'])
	/ comparison['total_energy_baseline'] * 100
)

# --- Spikes ---
spikes = (
	df_yesterday[df_yesterday['is_spike'] == 1]
	.groupby('serial')
	.size()
	.reset_index(name='spike_count')
)

# --- Plot ---
plt.figure(figsize=(10, 5))
for t in df_yesterday['type'].unique():
	sub = df_yesterday[df_yesterday['type'] == t]
	sub.groupby('unix_time')['energy'].sum().plot(label=t)

plt.title('System Consumption (Yesterday)')
plt.xlabel('Time')
plt.ylabel('Energy')
plt.legend()
plt.tight_layout()

plot_file = os.path.join(REPORTS_DIR, f"system_{yesterday.date()}.png")
plt.savefig(plot_file)
plt.close()

# --- Prepare LLM input ---
summary_data = {
	"date": str(yesterday.date()),
	"comparison": comparison.to_dict(orient='records'),
	"spikes": spikes.to_dict(orient='records')
}

prompt = f"""
You are an energy system analyst.

Compare yesterday's energy usage to the historical baseline.
Highlight:
- Major increases or decreases
- Possible operational issues
- Notable spikes or anomalies
- Actionable recommendations

Data:
{json.dumps(summary_data, indent=2)}
"""

# --- Hugging Face Hub ---
print("[INFO] Initializing Hugging Face InferenceClient...")
client = InferenceClient(token=HUGGINGFACE_API_KEY)

print("[INFO] Sending request to Hugging Face model...")
try:
	completion = client.chat.completions.create(
		model="openai/gpt-oss-120b",
		messages=[{"role": "user", "content": prompt}],
	)
	llm_summary = completion.choices[0].message['content']
	print("[HF] LLM summary received successfully")
except Exception as e:
	print("[HF] Request failed:", e)
	llm_summary = "LLM request failed"

summary_data['llm_summary'] = llm_summary

# --- Save report ---
report_file = os.path.join(REPORTS_DIR, f"report_{yesterday.date()}.json")
with open(report_file, 'w') as f:
	json.dump(summary_data, f, indent=2)

print(f"[INFO] Report saved: {report_file}")
