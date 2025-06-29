async function fetchAndRenderAlarms() {
	const container = document.getElementById('alarmContainer');
	container.innerHTML = '';

	const response = await fetch('/api/alarms');
	const data = await response.json();

	data.forEach(group => {
		const groupDiv = document.createElement('div');
		groupDiv.className = 'alarm-group';
		groupDiv.textContent = group.group_name;
		container.appendChild(groupDiv);

		let lastSerial = '';
		group.alarms.forEach((alarm) => {
			const isNewSerial = alarm.serial !== lastSerial;
			if (isNewSerial) {
				const infoDiv = document.createElement('div');
				infoDiv.className = 'alarm-info';
				infoDiv.innerHTML = `<a href="detail.epl?serial=${alarm.serial}">${alarm.serial}</a> ${alarm.info || ''}`;
				container.appendChild(infoDiv);

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
				lastSerial = alarm.serial;
			}

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
}

document.addEventListener('DOMContentLoaded', fetchAndRenderAlarms);
