let allAlarmsData = []; // global, preserved
let currentLinkIndex = -1; // index for keyboard navigation

const SCROLL_KEY = 'alarms_scroll';

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmSearch');
	const activeCheckbox = document.getElementById('activeAlarms');
	const container = document.getElementById('alarmContainer');

	// =======================================================
	// Event Delegation for Phone Links
	// =======================================================
	container.addEventListener('click', function (e) {
		const targetLink = e.target.closest('.phone-link');
		if (!targetLink) return;

		e.preventDefault();

		const phone = targetLink.dataset.phone;
		if (filterInput && phone) {
			filterInput.value = phone;
			filterAlarms(); // Calls URL sync and UI re-render
			filterInput.focus();
		}
	});

	// Helper: Check if alarm is active
	const isActiveAlarm = alarm =>
		Number(alarm.enabled) > 0 &&
		Number(alarm.condition_state) > 0;

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
	// URL STATE HANDLING
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

	// =========================
	// SCROLL (global manager)
	// =========================
	bindScrollPersistence(SCROLL_KEY);
	enableAutoRestore(SCROLL_KEY);

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

				// --- CSS VIRTUALIZATION FIX ---
				// Creates a master block to hold both the info header AND the table.
				// This allows Safari to hide them both together via content-visibility.
				const serialBlock = document.createElement('div');
				serialBlock.className = 'alarm-serial-block';

				const infoDiv = document.createElement('div');
				infoDiv.className = 'alarm-info';
				infoDiv.innerHTML = `<a href="detail.epl?serial=${alarmInfo.serial}">${alarmInfo.serial}</a> ${alarmInfo.info || ''}`;
				
				// Append title to the new block instead of the main container
				serialBlock.appendChild(infoDiv);

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

					// Build the phone link with E164 formatted number just like sms_sent.js
					let smsReceiverHtml = '';
					if (alarm.sms_notification) {
						let displayPhone = alarm.sms_notification;
						let dataPhone = alarm.sms_notification;

						// Use your wrapper logic
						const phoneObj = NabovarmeNumberPhone.new(alarm.sms_notification);

						if (phoneObj && phoneObj.isValid()) {
							// Standard readable phone formatting
							displayPhone = phoneObj.obj.formatInternational();

							// Match the dataset phone string format
							dataPhone = phoneObj.compact();
						}

						smsReceiverHtml = `
							<a href="#" class="phone-link" style="white-space: nowrap;" data-phone="${dataPhone}">${displayPhone}</a>
							<span style="display: none;">${alarm.sms_notification}</span>
						`;
					}

					rowDiv.innerHTML = `
						<div><a href="alarms_detail.epl?id=${alarm.id}">${alarm.id || ''}</a></div>
						<div>${smsReceiverHtml}</div>
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

				// Append table to the new block
				serialBlock.appendChild(tableWrapper);
				
				// Finally, append the entire wrapped block to the main container
				container.appendChild(serialBlock);
			});
		});
	}

	// Filter alarms and re-render
	function filterAlarms() {
		const searchText = filterInput.value.toLowerCase();
		const activeOnly = activeCheckbox.checked;

		// sync URL state
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

	// =========================================================================
	// FIX: Replaced `offsetParent` layout check with passive visual boundaries.
	// Prevents iOS Safari out-of-memory thread crashing during pinch-to-zoom.
	// =========================================================================
	function getVisibleAlarmLinks() {
		return Array.from(document.querySelectorAll('.alarm-row a, .alarm-info a'));
	}

	document.addEventListener('keydown', (e) => {
		// Exit early so we don't calculate layout sizes on random typing
		if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;

		const menuEl = document.getElementById('menu');

		// If the menu is open, don't navigate alarms
		if (menuEl && menuEl.classList.contains('show')) return;

		// Filter passively to protect the WebKit renderer thread
		const links = getVisibleAlarmLinks().filter(link => {
			const rect = link.getBoundingClientRect();
			return (rect.width > 0 || rect.height > 0);
		});

		if (!links.length) return;

		e.preventDefault();

		if (e.key === 'ArrowDown') {
			currentLinkIndex = (currentLinkIndex + 1) % links.length;
			links[currentLinkIndex].focus();
		} else if (e.key === 'ArrowUp') {
			currentLinkIndex = (currentLinkIndex - 1 + links.length) % links.length;
			links[currentLinkIndex].focus();
		}
	});

	// Initialize app
	async function init() {
		await fetchAlarms();

		// load state from URL
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
