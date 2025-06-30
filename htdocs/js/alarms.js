let allAlarmsData = []; // holds original API response

async function fetchAndRenderAlarms() {
	const container = document.getElementById('alarmContainer');
	container.innerHTML = '';

	const response = await fetch('/api/alarms');
	const data = await response.json();
	allAlarmsData = data; // store for filtering
	renderAlarms(data);   // render everything initially
}

function renderAlarms(data) {
	const container = document.getElementById('alarmContainer');
	container.innerHTML = '';

	data.forEach(group => {
		// Group header
		const groupDiv = document.createElement('div');
		groupDiv.className = 'alarm-group';
		groupDiv.textContent = group.group_name;
		container.appendChild(groupDiv);

		// Group by serial in order
		const alarmsBySerial = {};
		const serialOrder = [];

		group.alarms.forEach(alarm => {
			if (!alarmsBySerial[alarm.serial]) {
				alarmsBySerial[alarm.serial] = [];
				serialOrder.push(alarm.serial);
			}
			alarmsBySerial[alarm.serial].push(alarm);
		});

		serialOrder.forEach(serial => {
			const alarms = alarmsBySerial[serial];
			const alarmInfo = alarms[0];

			// Info row
			const infoDiv = document.createElement('div');
			infoDiv.className = 'alarm-info';
			infoDiv.innerHTML = `<a href="detail.epl?serial=${alarmInfo.serial}">${alarmInfo.serial}</a> ${alarmInfo.info || ''}`;
			container.appendChild(infoDiv);

			// Columns row
			const columnsDiv = document.createElement('div');
			columnsDiv.className = 'alarm-columns';
			columnsDiv.innerHTML = `
				<div>ID</div>
				<div>Alarm receiver</div>
				<div>Condition</div>
				<div>Repeating</div>
				<div>Snoozed</div>
				<div>Comment</div>
			`;
			container.appendChild(columnsDiv);

			// Alarm rows
			alarms.forEach(alarm => {
				const rowDiv = document.createElement('div');
				rowDiv.className = 'alarm-row';
				if (alarm.alarm_state > 0 && alarm.enabled > 0) rowDiv.classList.add('alarm-active');

				const repeat = alarm.repeat ? `every ${alarm.repeat}` : 'no';
				const snooze = alarm.snooze ? alarm.snooze : 'no';

				rowDiv.innerHTML = `
					<div><a href="alarms_detail.epl?id=${alarm.id}">${alarm.id || ''}</a></div>
					<div>${alarm.sms_notification || ''}</div>
					<div class="condition${alarm.enabled > 0 ? '' : ' alarm-disabled'}${(alarm.condition_error && alarm.condition_error !== '' && alarm.enabled > 0) ? ' condition-error' : ''}">
						${alarm.condition || ''}
					</div>
					<div>${repeat}</div>
					<div>${snooze}</div>
					<div>${alarm.comment || ''}</div>
				`;

				container.appendChild(rowDiv);
			});
		});
	});
}

function filterAndRenderAlarms() {
	const searchText = document.getElementById('alarmFilter').value.toLowerCase();
	const activeOnly = document.getElementById('alarmSearch').checked;

	const filteredData = allAlarmsData.map(group => {
		// Filter alarms in this group
		const filteredAlarms = group.alarms.filter(alarm => {
			const matchesSearch = searchText === '' || (
				(alarm.serial || '').toLowerCase().includes(searchText) ||
				(alarm.comment || '').toLowerCase().includes(searchText) ||
				(alarm.condition || '').toLowerCase().includes(searchText) ||
				(String(alarm.id) || '').includes(searchText)
			);

			const matchesActive = !activeOnly || (alarm.alarm_state > 0 && alarm.enabled > 0);

			return matchesSearch && matchesActive;
		});

		return {
			group_name: group.group_name,
			alarms: filteredAlarms
		};
	}).filter(group => group.alarms.length > 0); // drop empty groups

	renderAlarms(filteredData);
}

document.addEventListener('DOMContentLoaded', () => {
	fetchAndRenderAlarms();

	document.getElementById('alarmFilter').addEventListener('input', filterAndRenderAlarms);
	document.getElementById('alarmSearch').addEventListener('change', filterAndRenderAlarms);
});