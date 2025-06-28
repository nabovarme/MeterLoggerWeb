document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('alarmFilter');

	function filterAlarms() {
		const filter = filterInput.value.trim().toLowerCase();
		const tables = document.querySelectorAll('body > table'); // all top-level alarm tables
		let anyMatchFound = false;

		tables.forEach(table => {
			let anyVisible = false;

			// Select all rows with the base class 'alarm-row'
			const alarmRows = table.querySelectorAll('tr.alarm-row');

			alarmRows.forEach(row => {
				const text = row.textContent.toLowerCase();
				if (!filter || text.includes(filter)) {
					row.style.display = '';
					anyVisible = true;
					anyMatchFound = true;
				} else {
					row.style.display = 'none';
				}
			});

			// Header and column row visibility
			const groupHeaderRow = table.querySelector('tr td span.default-group')?.closest('tr');
			const columnHeaderRows = [...table.querySelectorAll('tr')].filter(tr =>
				tr.querySelector('td span.default-bold')
			);

			if (anyVisible) {
				if (groupHeaderRow) groupHeaderRow.style.display = '';
				columnHeaderRows.forEach(row => row.style.display = '');
				table.style.display = '';
			} else {
				if (groupHeaderRow) groupHeaderRow.style.display = 'none';
				columnHeaderRows.forEach(row => row.style.display = 'none');
				table.style.display = 'none';
			}
		});

		// Scroll to top only if there's a match and a filter value
		if (filter && anyMatchFound) {
			window.scrollTo({ top: 0, behavior: 'smooth' });
		}
	}

	filterInput.addEventListener('input', filterAlarms);
});
