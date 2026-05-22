let allAlarmsData = [];
let currentLinkIndex = -1;

const SCROLL_KEY = 'alarms_scroll';

if ('scrollRestoration' in history) {
	history.scrollRestoration = 'manual';
}

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmSearch');
	const activeCheckbox = document.getElementById('activeAlarms');
	const container = document.getElementById('alarmContainer');

	container.style.opacity = '0'; // Mask to prevent jump

	// Event Delegation for Phone Links
	container.addEventListener('click', function (e) {
		const targetLink = e.target.closest('.phone-link');
		if (!targetLink) return;
		e.preventDefault();
		const phone = targetLink.dataset.phone;
		if (filterInput && phone) {
			filterInput.value = phone;
			filterAlarms();
			filterInput.focus();
		}
	});

	const isActiveAlarm = alarm => Number(alarm.enabled) > 0 && Number(alarm.condition_state) > 0;

	const matchesSearch = (alarm, searchText) => {
		const textToCheck = [alarm.info, alarm.serial, alarm.comment, alarm.condition, alarm.sms_notification].map(s => (s || '').toLowerCase()).join(' ');
		return searchText === '' || textToCheck.includes(searchText);
	};

	function secToHHMM(sec) {
		if (sec === null || sec === undefined || sec === '') return '';
		const s = Number(sec);
		if (isNaN(s)) return '';
		return `${String(Math.floor(s / 3600)).padStart(2, '0')}:${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}`;
	}

	function updateURLState(searchText, activeOnly) {
		const params = new URLSearchParams(window.location.search);
		searchText ? params.set('q', searchText) : params.delete('q');
		activeOnly ? params.set('active', '1') : params.delete('active');
		history.replaceState(null, '', `${window.location.pathname}?${params.toString()}`);
	}

	function loadStateFromURL() {
		const params = new URLSearchParams(window.location.search);
		return { search: params.get('q') || '', activeOnly: params.get('active') === '1' };
	}

	bindScrollPersistence(SCROLL_KEY);
	enableAutoRestore(SCROLL_KEY);

	async function fetchAlarms() {
		try {
			const response = await fetch('/api/alarms');
			if (!response.ok) throw new Error(`API error: ${response.status}`);
			allAlarmsData = await response.json();
			return allAlarmsData;
		} catch (error) {
			container.innerHTML = `<p class="error">Failed to load alarms: ${error.message}</p>`;
			return [];
		}
	}

	function renderAlarms(data) {
		container.innerHTML = '';
		data.forEach(group => {
			const groupDiv = document.createElement('div');
			groupDiv.className = 'alarm-group';
			groupDiv.textContent = group.group_name;
			container.appendChild(groupDiv);

			const alarmsBySerial = {};
			const serialOrder = [];
			group.alarms.forEach(alarm => {
				if (!alarmsBySerial[alarm.serial]) { alarmsBySerial[alarm.serial] = []; serialOrder.push(alarm.serial); }
				alarmsBySerial[alarm.serial].push(alarm);
			});

			serialOrder.forEach(serial => {
				const alarms = alarmsBySerial[serial];
				const alarmInfo = alarms[0];
				const serialBlock = document.createElement('div');
				serialBlock.className = 'alarm-serial-block';

				const infoDiv = document.createElement('div');
				infoDiv.className = 'alarm-info';
				infoDiv.innerHTML = `<a href="detail.epl?serial=${alarmInfo.serial}">${alarmInfo.serial}</a> ${alarmInfo.info || ''}`;
				serialBlock.appendChild(infoDiv);

				const tableWrapper = document.createElement('div');
				tableWrapper.className = 'alarm-table-wrapper';
				tableWrapper.innerHTML = `
					<div class="alarm-columns">
						<div>ID</div><div>Alarm receiver</div><div>Condition</div>
						<div>Repeating</div><div>Snoozed</div><div>Active window</div><div>Comment</div>
					</div>`;
				
				alarms.forEach(alarm => {
					const rowDiv = document.createElement('div');
					rowDiv.className = 'alarm-row' + (isActiveAlarm(alarm) ? ' alarm-active' : '');
					
					const from = secToHHMM(alarm.active_from_sec);
					const to = secToHHMM(alarm.active_to_sec);
					let windowText = (from || to) ? `${from || ''} → ${to || ''}` : '';

					let smsReceiverHtml = '';
					if (alarm.sms_notification) {
						const phoneObj = NabovarmeNumberPhone.new(alarm.sms_notification);
						smsReceiverHtml = `<a href="#" class="phone-link" style="white-space: nowrap;" data-phone="${phoneObj && phoneObj.isValid() ? phoneObj.compact() : alarm.sms_notification}">${phoneObj && phoneObj.isValid() ? phoneObj.obj.formatInternational() : alarm.sms_notification}</a>`;
					}

					rowDiv.innerHTML = `
						<div><a href="alarms_detail.epl?id=${alarm.id}">${alarm.id || ''}</a></div>
						<div>${smsReceiverHtml}</div>
						<div class="condition${alarm.enabled > 0 ? '' : ' alarm-disabled'}">${alarm.condition}</div>
						<div>${alarm.repeat ? `every ${alarm.repeat}` : 'no'}</div>
						<div>${alarm.snooze || 'no'}</div>
						<div>${windowText}</div>
						<div>${alarm.comment || ''}</div>`;
					tableWrapper.appendChild(rowDiv);
				});
				serialBlock.appendChild(tableWrapper);
				container.appendChild(serialBlock);
			});
		});
	}

	function filterAlarms() {
		const searchText = filterInput.value.toLowerCase();
		const activeOnly = activeCheckbox.checked;
		updateURLState(searchText, activeOnly);
		const filteredData = allAlarmsData.map(group => ({
			group_name: group.group_name,
			alarms: group.alarms.filter(alarm => matchesSearch(alarm, searchText) && (!activeOnly || isActiveAlarm(alarm)))
		})).filter(group => group.alarms.length > 0);
		renderAlarms(filteredData);
		currentLinkIndex = -1;
	}

	function debounce(fn, delay = 300) {
		let timeoutId;
		return (...args) => { clearTimeout(timeoutId); timeoutId = setTimeout(() => fn(...args), delay); };
	}

	document.addEventListener('keydown', (e) => {
		if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
		const menuEl = document.getElementById('menu');
		if (menuEl && menuEl.classList.contains('show')) return;
		const links = Array.from(document.querySelectorAll('.alarm-row a, .alarm-info a')).filter(l => l.getBoundingClientRect().width > 0);
		if (!links.length) return;
		e.preventDefault();
		currentLinkIndex = e.key === 'ArrowDown' ? (currentLinkIndex + 1) % links.length : (currentLinkIndex - 1 + links.length) % links.length;
		links[currentLinkIndex].focus();
	});

	async function init() {
		await fetchAlarms();
		const urlState = loadStateFromURL();
		filterInput.value = urlState.search;
		activeCheckbox.checked = urlState.activeOnly;
		filterAlarms();

		const savedY = parseInt(sessionStorage.getItem(SCROLL_KEY) || '0', 10);
		if (savedY > 0) {
			container.style.minHeight = (savedY + 2000) + 'px';
			window.scrollTo(0, savedY);
			setTimeout(() => { container.style.minHeight = ''; container.style.opacity = '1'; }, 150);
		} else {
			container.style.opacity = '1';
		}

		filterInput.addEventListener('input', debounce(filterAlarms));
		activeCheckbox.addEventListener('change', filterAlarms);
	}
	init();
});
