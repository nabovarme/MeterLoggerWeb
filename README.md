
# MeterLoggerWeb

**MeterLoggerWeb** is the backend monitoring and alarm system for MeterLogger devices. It processes meter data, evaluates user-defined alarm conditions, and sends SMS notifications based on various metrics and conditions.

---

## 🚀 Build & Setup

To build and run the service with Docker:

```sh
docker compose up --build
```

To initialize the database (**only the first time**):

```sh
docker exec -it db /nabovarme_setup.sh
docker cp mysql_backup.sql.bz2 db:/tmp/
docker exec -it db /nabovarme_import.sh
docker exec -it db /nabovarme_triggers.sh
```

---

## 📌 Built-in / Static Variables

These are predefined variables available in alarm conditions and messages. They are fetched directly from the `meters` and `alarms` tables.

| Variable             | Description                                                                 |
|----------------------|-----------------------------------------------------------------------------|
| `$serial`            | Serial number of the meter                                                  |
| `$info`              | `info` field from the `meters` table                                        |
| `$offline`           | Number of seconds since last update (`now - last_updated`)                 |
| `$id`                | ID of the alarm (mostly for templating, not logic)                          |
| `$default_snooze`    | Default snooze duration (in seconds) for this alarm                         |

---

## 📊 Dynamic Sample-Based Variables

These variables are computed by querying the last 5 rows from `samples_cache` for the meter's serial. The system calculates the **median** value.

| Variable             | Description                                                                 |
|----------------------|-----------------------------------------------------------------------------|
| `$energy`            | Median of last 5 values from `samples_cache.energy`                         |
| `$volume`            | Median of last 5 values from `samples_cache.volume`                         |
| `$kwh_left`          | Median of last 5 values from `samples_cache.kwh_left` (if present)          |
| `$valve_status`      | Median (numeric) of last 5 values from `samples_cache.valve_status`         |
| `$valve_installed`   | From `meters.valve_installed` (not sample-based)                            |
| `$your_column`       | Any other column from `samples_cache` can be used the same way              |

✅ Use any valid column name in `samples_cache` as `$column_name`, and it will be replaced with the median of the last 5 values.

---

## 🕒 Recently Added / Time-Windowed Variables

These are **delta values** calculated over the **last 24 hours**, excluding the most recent **10 minutes** to account for hardware response delay (like valve closing time).

| Variable         | Description                                                                 |
|------------------|-----------------------------------------------------------------------------|
| `$energy_day`    | Difference in `energy` between 24h+10min ago and 10min ago                  |
| `$volume_day`    | Difference in `volume` between 24h+10min ago and 10min ago                  |

📎 **Note:** These help detect ongoing usage or flow even after valve closure.

---

## ✉️ SMS Templates

In the `down_message` and `up_message` fields, you can use any of the above variables with `$` notation. For example:

```text
Alert: $serial has used $volume_day liters in the past 24 hours.
Snooze link: https://example.com/snooze/$snooze_auth_key
```

---

## 🔐 Security

- `snooze_auth_key` is a random token used for snoozing alarms via user links.
- Avoid exposing sensitive alarm conditions in user-facing templates.

---

## 🧪 Example Alarm Condition

```perl
$offline > 3600 && $volume_day > 50
```

This condition triggers if the meter has been offline for more than an hour and has used more than 50 liters in the last 24 hours.

---

## 🛠️ Development Tips

- Use `alarm_state`, `last_notification`, and `snooze` to control notification logic.
- Logs are printed to STDOUT for debug; check container logs if running via Docker.

---
