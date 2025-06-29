document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');
	const alarmSearchCheckbox = document.getElementById('alarmSearch');

	function filterAlarms() {
		const filterText = filterInput.value.trim().toLowerCase();
		const alarmSearch = alarmSearchCheckbox.checked;

		// Get all tables (each group block is a separate table)
		const tables = document.querySelectorAll('table');

		tables.forEach(table => {
			const alarmRows = table.querySelectorAll('tr.alarm-row');
			let anyAlarmVisibleInTable = false;

			alarmRows.forEach(row => {
				const isAlarmRed = row.classList.contains('alarm-red');
				const textContent = row.textContent.toLowerCase();

				let match;
				if (alarmSearch) {
					// When checkbox checked: show only red alarms matching search
					match = isAlarmRed && textContent.includes(filterText);
				} else {
					// Normal search: show any alarms matching search text
					match = textContent.includes(filterText);
				}

				row.style.display = match ? '' : 'none';
				if (match) anyAlarmVisibleInTable = true;
			});

			// Process info-row and columns-row visibility based on visible alarms
			const infoRows = table.querySelectorAll('tr.info-row');

			infoRows.forEach(infoRow => {
				let columnsRow = infoRow.nextElementSibling;
				if (!columnsRow || !columnsRow.classList.contains('columns-row')) return;

				let currentRow = columnsRow.nextElementSibling;
				let hasVisibleAlarm = false;
				let lastAlarmRow = null;

				while (
					currentRow &&
					!currentRow.classList.contains('info-row') &&
					!currentRow.classList.contains('group')
				) {
					if (currentRow.classList.contains('alarm-row')) {
						if (currentRow.style.display !== 'none') {
							hasVisibleAlarm = true;
						}
						lastAlarmRow = currentRow;
					}
					currentRow = currentRow.nextElementSibling;
				}

				let spacerRow = lastAlarmRow?.nextElementSibling;
				if (spacerRow && spacerRow.classList.contains('spacer-row')) {
					spacerRow.style.display = hasVisibleAlarm ? '' : 'none';
				}

				infoRow.style.display = hasVisibleAlarm ? '' : 'none';
				columnsRow.style.display = hasVisibleAlarm ? '' : 'none';
			});

			table.style.display = anyAlarmVisibleInTable ? '' : 'none';
		});
	}

	filterInput.addEventListener('input', filterAlarms);
	alarmSearchCheckbox.addEventListener('change', filterAlarms);

	// Initial filter run on page load
	filterAlarms();

	// Focus input on page load
	filterInput.focus();

	// Ctrl+F or Alt+F to focus search
	document.addEventListener('keydown', (e) => {
		if (
			filterInput &&
			e.key.toLowerCase() === 'f' &&
			(e.ctrlKey || e.altKey) &&
			!e.metaKey
		) {
			e.preventDefault();
			filterInput.focus();
		}
	});
});
