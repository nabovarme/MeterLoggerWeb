document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');
	const alarmSearchCheckbox = document.getElementById('alarmSearch');

	function filterAlarms() {
		const filterText = filterInput.value.trim().toLowerCase();
		const alarmSearch = alarmSearchCheckbox.checked;

		const tables = document.querySelectorAll('table');

		tables.forEach(table => {
			const rows = Array.from(table.querySelectorAll('tr'));
			let anyAlarmVisibleInTable = false;

			// Track if we are inside a matched group/info block
			let insideMatchedBlock = false;

			for (let i = 0; i < rows.length; i++) {
				const row = rows[i];
				const textContent = row.textContent.toLowerCase();

				const isGroup = row.classList.contains('group');
				const isInfo = row.classList.contains('info-row');
				const isAlarm = row.classList.contains('alarm-row');
				const isAlarmRed = row.classList.contains('alarm-red');

				let match = false;

				if (isGroup || isInfo) {
					match = textContent.includes(filterText);

					// Show this row if matches, hide otherwise
					row.style.display = match ? '' : 'none';

					if (match) {
						insideMatchedBlock = true;
						anyAlarmVisibleInTable = true;
					} else {
						insideMatchedBlock = false;
					}

					continue;
				}

				if (alarmSearch) {
					match = isAlarm && isAlarmRed && textContent.includes(filterText);
				} else {
					match = isAlarm && textContent.includes(filterText);
				}

				// Show the row if it matches or if it’s inside a matched group/info block
				const shouldShow = match || insideMatchedBlock;
				row.style.display = shouldShow ? '' : 'none';

				if (shouldShow && isAlarm) {
					anyAlarmVisibleInTable = true;
				}
			}

			// Existing logic to show/hide info-row and columns-row based on visible alarms
			const infoRows = table.querySelectorAll('tr.info-row');

			infoRows.forEach(infoRow => {
				const columnsRow = infoRow.nextElementSibling;
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

				const spacerRow = lastAlarmRow?.nextElementSibling;
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

	filterAlarms();
	filterInput.focus();

	document.addEventListener('keydown', e => {
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
