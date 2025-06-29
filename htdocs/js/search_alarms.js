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

			// First pass: show/hide group, info, alarm and other rows
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
						// Hide for now; fix later in second pass
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

				// Other rows (e.g. spacer-row)
				row.style.display = insideMatchedBlock || alarmsVisibleInBlock ? '' : 'none';
			}

			// Second pass for alarmSearch: fix group and info-row visibility based on alarms shown
			if (alarmSearch) {
				for (let i = 0; i < rows.length; i++) {
					const row = rows[i];
					if (row.classList.contains('group')) {
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

		// Scroll page to top smoothly after every search/filter update
		window.scrollTo({ top: 0, behavior: 'smooth' });
	}

	filterInput.addEventListener('input', filterAlarms);
	alarmSearchCheckbox.addEventListener('change', filterAlarms);

	// Run once on page load to set initial visibility
	filterAlarms();

	// Focus input on load
	filterInput?.focus();

	// Ctrl+F or Alt+F focus shortcut
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
