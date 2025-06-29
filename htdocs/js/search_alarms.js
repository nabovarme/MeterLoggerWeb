document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');
	const alarmSearchCheckbox = document.getElementById('alarmSearch');

	function filterAlarms() {
		const filterText = filterInput.value.trim().toLowerCase();
		const alarmSearch = alarmSearchCheckbox.checked;

		const tables = document.querySelectorAll('table');

		tables.forEach(table => {
			// Skip tables with class 'end-spacer'
			if (table.classList.contains('end-spacer')) return;

			const rows = Array.from(table.querySelectorAll('tr'));
			let anyAlarmVisibleInTable = false;

			let insideMatchedBlock = false;
			let alarmsVisibleInBlock = false;

			for (let i = 0; i < rows.length; i++) {
				const row = rows[i];
				const textContent = row.textContent.toLowerCase();

				const isGroup = row.classList.contains('group');
				const isInfo = row.classList.contains('info-row');
				const isAlarm = row.classList.contains('alarm-row');
				const isAlarmRed = row.classList.contains('alarm-red');

				let match = false;

				if (isGroup || isInfo) {
					if (!alarmSearch) {
						match = textContent.includes(filterText);
						row.style.display = match ? '' : 'none';

						insideMatchedBlock = match;
						alarmsVisibleInBlock = false;
					} else {
						// Delay showing group/info until alarms are processed
						row.style.display = 'none';
						insideMatchedBlock = false;
						alarmsVisibleInBlock = false;
					}
					continue;
				}

				if (isAlarm) {
					if (alarmSearch) {
						match = isAlarmRed && textContent.includes(filterText);
					} else {
						match = textContent.includes(filterText);
					}

					const shouldShow = alarmSearch ? match : (match || insideMatchedBlock);

					row.style.display = shouldShow ? '' : 'none';

					if (shouldShow) {
						anyAlarmVisibleInTable = true;
						alarmsVisibleInBlock = true;
					}
					continue;
				}

				// For other rows (e.g. spacer-row), show if insideMatchedBlock or alarms visible in block
				row.style.display = insideMatchedBlock || alarmsVisibleInBlock ? '' : 'none';
			}

			// Fix group and info-row visibility if alarmSearch is checked
			if (alarmSearch) {
				for (let i = 0; i < rows.length; i++) {
					const row = rows[i];
					if (row.classList.contains('group')) {
						// Show group only if any alarm in its block is visible
						let j = i + 1;
						let visibleAlarmFound = false;
						while (j < rows.length && !rows[j].classList.contains('group')) {
							if (
								rows[j].classList.contains('alarm-row') &&
								rows[j].style.display !== 'none'
							) {
								visibleAlarmFound = true;
								break;
							}
							j++;
						}
						row.style.display = visibleAlarmFound ? '' : 'none';
					}

					if (row.classList.contains('info-row')) {
						const columnsRow = row.nextElementSibling;
						let visibleAlarmFound = false;

						// Alarms after columns-row until next info or group
						let j = columnsRow && columnsRow.classList.contains('columns-row') ? i + 2 : i + 1;
						while (
							j < rows.length &&
							!rows[j].classList.contains('group') &&
							!rows[j].classList.contains('info-row')
						) {
							if (
								rows[j].classList.contains('alarm-row') &&
								rows[j].style.display !== 'none'
							) {
								visibleAlarmFound = true;
								break;
							}
							j++;
						}
						row.style.display = visibleAlarmFound ? '' : 'none';
						if (columnsRow && columnsRow.classList.contains('columns-row')) {
							columnsRow.style.display = visibleAlarmFound ? '' : 'none';
						}
					}
				}
			}

			// Show/hide spacer-rows based on previous alarm-row visibility
			for (let i = 0; i < rows.length; i++) {
				const row = rows[i];
				if (row.classList.contains('spacer-row')) {
					const prevRow = rows[i - 1];
					row.style.display =
						prevRow && prevRow.classList.contains('alarm-row') && prevRow.style.display !== 'none'
							? ''
							: 'none';
				}
			}

			// Show/hide entire table
			table.style.display = anyAlarmVisibleInTable ? '' : 'none';
		});
	}

	filterInput.addEventListener('input', filterAlarms);
	alarmSearchCheckbox.addEventListener('change', filterAlarms);

	// Run once on page load to set initial visibility
	filterAlarms();
});
