document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');
	const alarmSearchCheckbox = document.getElementById('alarmSearch');

	function filterAlarms() {
		const filterText = filterInput.value.trim().toLowerCase();
		const alarmSearch = alarmSearchCheckbox.checked;

		const tables = document.querySelectorAll('table');

		tables.forEach((table) => {
			if (table.classList.contains('end-spacer')) return;

			const rows = Array.from(table.querySelectorAll('tr'));

			let anyAlarmVisibleInTable = false;
			let insideMatchedBlock = false;
			let alarmsVisibleInBlock = false;

			// First pass: hide/show group/info/alarm rows
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

				// Default non-alarm row
				row.style.display = insideMatchedBlock || alarmsVisibleInBlock ? '' : 'none';
			}

			// Show group/info if alarms follow (alarmSearch mode)
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

			// Improved spacer-row logic
			for (let i = 0; i < rows.length; i++) {
				const row = rows[i];

				if (row.classList.contains('spacer-row')) {
					let showSpacer = false;

					// Look backward for visible alarm-row
					let prevVisibleAlarm = false;
					for (let j = i - 1; j >= 0; j--) {
						const prevRow = rows[j];
						if (prevRow.style.display === 'none') continue;
						if (prevRow.classList.contains('alarm-row')) {
							prevVisibleAlarm = true;
							break;
						}
						if (prevRow.classList.contains('group') || prevRow.classList.contains('info-row')) {
							break;
						}
					}

					// Look forward for visible info-row/group or table
					let nextVisibleType = null;
					for (let j = i + 1; j < rows.length; j++) {
						const nextRow = rows[j];
						if (nextRow.style.display === 'none') continue;
						if (
							nextRow.classList.contains('columns-row') ||
							nextRow.classList.contains('spacer-row')
						) continue;

						if (
							nextRow.classList.contains('group') ||
							nextRow.classList.contains('info-row')
						) {
							nextVisibleType = 'block';
						}
						break;
					}

					// No info/group found; look for next visible table
					if (!nextVisibleType) {
						let nextTable = table.nextElementSibling;
						while (nextTable) {
							if (
								nextTable.tagName === 'TABLE' &&
								!nextTable.classList.contains('end-spacer') &&
								nextTable.style.display !== 'none'
							) {
								nextVisibleType = 'table';
								break;
							}
							nextTable = nextTable.nextElementSibling;
						}
					}

					showSpacer = prevVisibleAlarm && !!nextVisibleType;
					row.style.display = showSpacer ? '' : 'none';
				}
			}

			table.style.display = anyAlarmVisibleInTable ? '' : 'none';
		});

		window.scrollTo({ top: 0, behavior: 'smooth' });
	}

	filterInput.addEventListener('input', filterAlarms);
	alarmSearchCheckbox.addEventListener('change', filterAlarms);
	filterAlarms();
	filterInput?.focus();

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
