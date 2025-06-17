# MeterLoggerWeb

MeterLoggerWeb is the backend system for MeterLogger

## Build details

docker compose up --build

To initialize db (only do it first time!):

docker exec -it db /nabovarme_setup.sh

docker cp mysql_backup.sql.bz2 db:/tmp/

docker exec -it db /nabovarme_import.sh

docker exec -it db /nabovarme_triggers.sh


## Built-in / Static Variables
These are computed directly in Perl without querying other tables:

### Symbolic Variable	Meaning
**$serial**	The serial number of the meter<br/>
**$info**	The info field from the meters table<br/>
**$offline**	Number of seconds since the meter last sent a sample (now - last_updated)<br/>
**$id**	ID of the alarm (used mostly in messages, not for logic)<br/>
**$default_snooze**	Default snooze time for this alarm<br/>

## Dynamic Sample-Based Variables
These values are fetched from the latest 5 rows of the samples_cache table for the given serial and median is calculated:

### Symbolic Variable	Meaning
**$energy**	Median of last 5 values from samples_cache.energy<br/>
**$volume**	Median of last 5 values from samples_cache.volume<br/>
**$kwh_left**	Median of last 5 values from samples_cache.kwh_left<br/>
**$valve_status**	Median (numeric) of last 5 values from samples_cache.valve_status<br/>
... (others)	Any other column in samples_cache may be referenced similarly<br/>

✅ You can use any column name from samples_cache as $your_column, and the system will replace it with the median of the last 5 values.

## Recently Added
These are special variables computed based on comparisons:

### Symbolic Variable	Meaning
**$last_volume**	The most recent volume value before the last check, stored per alarm<br/>
(coming soon)	You could similarly add $last_energy, etc., if needed
