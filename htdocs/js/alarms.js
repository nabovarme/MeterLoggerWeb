let allAlarmsData = []; // global, preserved

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');
	const activeCheckbox = document.getElementById('alarmSearch');
	const container = document.getElementById('alarmContainer');

	// Helper: Check if alarm is active
	const isActiveAlarm = alarm => alarm.alarm_state > 0 && alarm.enabled > 0;

	// Helper: Check if alarm matches search text
	const matchesSearch = (alarm, searchText) => {
		const textToCheck = [
			alarm.info,
			alarm.serial,
			alarm.comment,
			alarm.condition,
			alarm.sms_notification
		].map(s => (s || '').toLowerCase()).join(' ');
		return searchText === '' || textToCheck.includes(searchText);
	};

	// Fetch alarms from API
	async function fetchAlarms() {
		try {
			const response = await fetch('/api/alarms');
			if (!response.ok) throw new Error(`API error: ${response.status}`);
			const data = await response.json();
			allAlarmsData = data; // assign to global here
			return data;
		} catch (error) {
			showError(`Failed to load alarms: ${error.message}`);
			return [];
		}
	}

	// Show error message in container
	function showError(message) {
		container.innerHTML = `<p class="error">${message}</p>`;
	}

	// Render alarms to container
	function renderAlarms(data) {
		container.innerHTML = '';

		data.forEach(group => {
			const groupDiv = document.createElement('div');
			groupDiv.className = 'alarm-group';
			groupDiv.textContent = group.group_name;
			container.appendChild(groupDiv);

			// Group alarms by serial, maintaining order
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

				const infoDiv = document.createElement('div');
				infoDiv.className = 'alarm-info';
				infoDiv.innerHTML = `<a href="detail.epl?serial=${alarmInfo.serial}">${alarmInfo.serial}</a> ${alarmInfo.info || ''}`;
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

				alarms.forEach(alarm => {
					const rowDiv = document.createElement('div');
					rowDiv.className = 'alarm-row';
					if (isActiveAlarm(alarm)) rowDiv.classList.add('alarm-active');

					const repeat = alarm.repeat ? `every ${alarm.repeat}` : 'no';
					const snooze = alarm.snooze || 'no';

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

	// Filter alarms and re-render
	function filterAlarms() {
		const searchText = filterInput.value.toLowerCase();
		const activeOnly = activeCheckbox.checked;

		const filteredData = allAlarmsData.map(group => {
			const groupMatches = group.group_name.toLowerCase().includes(searchText);

			let filteredAlarms;

			if (groupMatches) {
				filteredAlarms = group.alarms.filter(alarm => !activeOnly || isActiveAlarm(alarm));
			} else {
				filteredAlarms = group.alarms.filter(alarm =>
					matchesSearch(alarm, searchText) && (!activeOnly || isActiveAlarm(alarm))
				);
			}

			return { group_name: group.group_name, alarms: filteredAlarms };
		}).filter(group => group.alarms.length > 0);

		renderAlarms(filteredData);

		// Scroll container to top after rendering filtered alarms
		container.scrollTop = 0;
	}

	// Debounce utility
	function debounce(fn, delay = 300) {
		let timeoutId;
		return (...args) => {
			clearTimeout(timeoutId);
			timeoutId = setTimeout(() => fn(...args), delay);
		};
	}

	// Initialize app
	async function init() {
		await fetchAlarms();
		renderAlarms(allAlarmsData);

		filterInput.addEventListener('input', debounce(filterAlarms));
		activeCheckbox.addEventListener('change', filterAlarms);

		// Focus search input on page load
		filterInput.focus();

		// Keyboard shortcuts: Ctrl+F or Alt+F to focus search
		document.addEventListener('keydown', (e) => {
			if ((e.ctrlKey || e.altKey) && e.key.toLowerCase() === 'f') {
				e.preventDefault();
				filterInput.focus();
			}
		});
	}

	init();
});
