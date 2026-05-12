let allAlarmsData = []; // global, preserved
let currentLinkIndex = -1; // index for keyboard navigation

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmSearch');
	const activeCheckbox = document.getElementById('activeAlarms');
	const container = document.getElementById('alarmContainer');

	// Helper: Check if alarm is active
	const isActiveAlarm = alarm =>
		Number(alarm.enabled) > 0 &&
		Number(alarm.alarm_state) > 0;

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

	// Convert seconds since midnight → HH:MM
	function secToHHMM(sec) {
		if (sec === null || sec === undefined || sec === '') return '';

		const s = Number(sec);
		if (isNaN(s)) return '';

		const h = String(Math.floor(s / 3600)).padStart(2, '0');
		const m = String(Math.floor((s % 3600) / 60)).padStart(2, '0');

		return `${h}:${m}`;
	}

	// =========================
	// URL STATE HANDLING (NEW)
	// =========================

	function updateURLState(searchText, activeOnly) {
		const params = new URLSearchParams(window.location.search);

		if (searchText) {
			params.set('q', searchText);
		} else {
			params.delete('q');
		}

		if (activeOnly) {
			params.set('active', '1');
		} else {
			params.delete('active');
		}

		const newUrl = `${window.location.pathname}?${params.toString()}`;
		history.replaceState(null, '', newUrl);
	}

	function loadStateFromURL() {
		const params = new URLSearchParams(window.location.search);

		return {
			search: params.get('q') || '',
			activeOnly: params.get('active') === '1'
		};
	}

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

				// Create wrapper for table
				const tableWrapper = document.createElement('div');
				tableWrapper.className = 'alarm-table-wrapper';

				// Add columns
				const columnsDiv = document.createElement('div');
				columnsDiv.className = 'alarm-columns';
				columnsDiv.innerHTML = `
					<div>ID</div>
					<div>Alarm receiver</div>
					<div>Condition</div>
					<div>Repeating</div>
					<div>Snoozed</div>
					<div>Active window</div>
					<div>Comment</div>
				`;
				tableWrapper.appendChild(columnsDiv);

				// Add each row
				alarms.forEach(alarm => {
					const rowDiv = document.createElement('div');
					rowDiv.className = 'alarm-row';
					if (isActiveAlarm(alarm)) rowDiv.classList.add('alarm-active');

					const repeat = alarm.repeat ? `every ${alarm.repeat}` : 'no';
					const snooze = alarm.snooze || 'no';

					const from = secToHHMM(alarm.active_from_sec);
					const to = secToHHMM(alarm.active_to_sec);

					let windowText = '';
					if (from && to) {
						windowText = `${from} → ${to}`;
					} else if (from) {
						windowText = `${from} →`;
					} else if (to) {
						windowText = `→ ${to}`;
					} else {
						windowText = '';
					}

					rowDiv.innerHTML = `
						<div><a href="alarms_detail.epl?id=${alarm.id}">${alarm.id || ''}</a></div>
						<div>${alarm.sms_notification || ''}</div>
						<div class="condition${alarm.enabled > 0 ? '' : ' alarm-disabled'}${(alarm.condition_error && alarm.condition_error !== '' && alarm.enabled > 0) ? ' condition-error' : ''}">
							${alarm.condition}
						</div>
						<div>${repeat}</div>
						<div>${snooze}</div>
						<div>${windowText}</div>
						<div>${alarm.comment || ''}</div>
					`;

					tableWrapper.appendChild(rowDiv);
				});

				container.appendChild(tableWrapper);
			});
		});
	}

	// Filter alarms and re-render
	function filterAlarms() {
		const searchText = filterInput.value.toLowerCase();
		const activeOnly = activeCheckbox.checked;

		// NEW: sync URL state
		updateURLState(searchText, activeOnly);

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

		// Reset keyboard navigation
		currentLinkIndex = -1;
	}

	// Debounce utility
	function debounce(fn, delay = 300) {
		let timeoutId;
		return (...args) => {
			clearTimeout(timeoutId);
			timeoutId = setTimeout(() => fn(...args), delay);
		};
	}

	// Keyboard navigation using Arrow Up / Arrow Down
	function getVisibleAlarmLinks() {
		return Array.from(document.querySelectorAll('.alarm-row a, .alarm-info a'))
			.filter(link => link.offsetParent !== null); // only visible links
	}

	document.addEventListener('keydown', (e) => {
		const menuEl = document.getElementById('menu');

		// If the menu is open, don't navigate meters
		if (menuEl && menuEl.classList.contains('show')) return;

		const links = getVisibleAlarmLinks();
		if (!links.length) return;

		if (e.key === 'ArrowDown') {
			e.preventDefault();
			currentLinkIndex = (currentLinkIndex + 1) % links.length;
			links[currentLinkIndex].focus();
		} else if (e.key === 'ArrowUp') {
			e.preventDefault();
			currentLinkIndex = (currentLinkIndex - 1 + links.length) % links.length;
			links[currentLinkIndex].focus();
		}
	});

	// Initialize app
	async function init() {
		await fetchAlarms();

		// NEW: load state from URL
		const urlState = loadStateFromURL();

		renderAlarms(allAlarmsData);

		filterInput.value = urlState.search;
		activeCheckbox.checked = urlState.activeOnly;

		// Apply initial filter (important so URL state is respected)
		filterAlarms();

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
