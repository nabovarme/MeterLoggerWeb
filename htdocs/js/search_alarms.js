document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');

	// Filter function on input
	filterInput.addEventListener('input', () => {
		const filterText = filterInput.value.trim().toLowerCase();

		// Get all tables (each group block is a separate table)
		const tables = document.querySelectorAll('table');

		tables.forEach(table => {
			const alarmRows = table.querySelectorAll('tr.alarm-row');
			let anyAlarmVisibleInTable = false;

			alarmRows.forEach(row => {
				const textContent = row.textContent.toLowerCase();
				const match = textContent.includes(filterText);
				row.style.display = match ? '' : 'none';
				if (match) anyAlarmVisibleInTable = true;
			});

			// Process each info-row (and its associated rows)
			const infoRows = table.querySelectorAll('tr.info-row');

			infoRows.forEach(infoRow => {
				let columnsRow = infoRow.nextElementSibling;
				if (!columnsRow || !columnsRow.classList.contains('columns-row')) return;

				let currentRow = columnsRow.nextElementSibling;
				let hasVisibleAlarm = false;
				let lastAlarmRow = null;

				// Traverse alarm rows after columnsRow
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

				// Possibly get spacer-row right after last alarm-row
				let spacerRow = lastAlarmRow?.nextElementSibling;
				if (spacerRow && spacerRow.classList.contains('spacer-row')) {
					spacerRow.style.display = hasVisibleAlarm ? '' : 'none';
				}

				infoRow.style.display = hasVisibleAlarm ? '' : 'none';
				columnsRow.style.display = hasVisibleAlarm ? '' : 'none';
			});

			table.style.display = anyAlarmVisibleInTable ? '' : 'none';
		});
	});

	// Focus input on page load
	filterInput.focus();

	// Focus input on Ctrl+F or Alt+F
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
