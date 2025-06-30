let allMetersData = []; // global, preserved

document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('meterSearch');
	const activeCheckbox = document.getElementById('disabledMeters');
	const container = document.getElementById('meterContainer');

	// Helper: Check if meter is active
	const isActiveMeter = meter => meter.meter_state > 0 && meter.enabled > 0;

	// Helper: Check if meter matches search text
	const matchesSearch = (meter, searchText) => {
		const textToCheck = [
			meter.info,
			meter.serial
		].map(s => (s || '').toLowerCase()).join(' ');
		return searchText === '' || textToCheck.includes(searchText);
	};

	// Fetch meterss from API
	async function fetchMeters() {
		try {
			const response = await fetch('/api/meters');
			if (!response.ok) throw new Error(`API error: ${response.status}`);
			const data = await response.json();
			allMetersData = data; // assign to global here
			return data;
		} catch (error) {
			showError(`Failed to load meters: ${error.message}`);
			return [];
		}
	}

	// Show error message in container
	function showError(message) {
		container.innerHTML = `<p class="error">${message}</p>`;
	}

	// Render meters to container
	function renderMeters(data) {
		container.innerHTML = '';

		data.forEach(group => {
			const groupDiv = document.createElement('div');
			groupDiv.className = 'meter-group';
			groupDiv.textContent = group.group_name;
			container.appendChild(groupDiv);

			// Group meters by serial, maintaining order
			const metersBySerial = {};
			const serialOrder = [];
			group.meters.forEach(meter => {
				if (!metersBySerial[meter.serial]) {
					metersBySerial[meter.serial] = [];
					serialOrder.push(meter.serial);
				}
				metersBySerial[meter.serial].push(meter);
			});

			serialOrder.forEach(serial => {
				const meters = metersBySerial[serial];
				const meterInfo = meters[0];

				const infoDiv = document.createElement('div');
				infoDiv.className = 'meter-info';
				infoDiv.innerHTML = `<a href="detail.epl?serial=${meterInfo.serial}">${meterInfo.serial}</a> ${meterInfo.info || ''}`;
				container.appendChild(infoDiv);

				// Create wrapper for table
				const tableWrapper = document.createElement('div');
				tableWrapper.className = 'meter-table-wrapper';

				// Add columns
				const columnsDiv = document.createElement('div');
				columnsDiv.className = 'meter-columns';
				columnsDiv.innerHTML = `
					<div>Serial</div>
					<div>Info receiver</div>
					<div>Energy</div>
					<div>Volume</div>
					<div>Hours</div>
					<div>Left</div>
					<div>Time left</div>
				`;
				tableWrapper.appendChild(columnsDiv);

				// Add each row
				meters.forEach(meter => {
					const rowDiv = document.createElement('div');
					rowDiv.className = 'meter-row';
					if (isActiveMeter(meter)) rowDiv.classList.add('meter-active');

					const repeat = meter.repeat ? `every ${meter.repeat}` : 'no';
					const snooze = meter.snooze || 'no';

					rowDiv.innerHTML = `
						<div><a href="meters_detail.epl?id=${meter.id}">${meter.id || ''}</a></div>
						<div>${meter.sms_notification || ''}</div>
						<div class="condition${meter.enabled > 0 ? '' : ' meter-disabled'}${(meter.condition_error && meter.condition_error !== '' && meter.enabled > 0) ? ' condition-error' : ''}">
							${meter.condition || ''}
						</div>
						<div>${repeat}</div>
						<div>${snooze}</div>
						<div>${meter.comment || ''}</div>
					`;

					tableWrapper.appendChild(rowDiv);
				});

				container.appendChild(tableWrapper);
			});
		});
	}

	// Filter meters and re-render
	function filterMeters() {
		const searchText = filterInput.value.toLowerCase();
		const activeOnly = activeCheckbox.checked;

		const filteredData = allMetersData.map(group => {
			const groupMatches = group.group_name.toLowerCase().includes(searchText);

			let filteredMeters;

			if (groupMatches) {
				filteredMeters = group.meters.filter(meter => !activeOnly || isActiveMeter(meter));
			} else {
				filteredMeters = group.meters.filter(meter =>
					matchesSearch(meter, searchText) && (!activeOnly || isActiveMeter(meter))
				);
			}

			return { group_name: group.group_name, meters: filteredMeters };
		}).filter(group => group.meters.length > 0);

		renderMeters(filteredData);

		// Scroll container to top after rendering filtered meters
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
		await fetchMeters();
		renderMeters(allMetersData);

		filterInput.addEventListener('input', debounce(filterMeters));
		activeCheckbox.addEventListener('change', filterMeters);

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
