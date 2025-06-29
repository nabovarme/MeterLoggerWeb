document.addEventListener('DOMContentLoaded', () => {
	const filterInput = document.getElementById('meterSearch');

	filterInput.addEventListener('input', () => {
		const filterText = filterInput.value.trim().toLowerCase();

		const rows = Array.from(document.querySelectorAll('tr'));
		let currentGroup = null;
		let currentColumns = null;
		let groupHasMatch = false;

		// Keep track of visible meter-rows to handle spacer-row check
		const visibleMeterRowIndices = new Set();

		// First pass: match and hide/show rows
		rows.forEach((row, index) => {
			if (row.classList.contains('group')) {
				// Handle previous group before starting new one
				if (currentGroup && !groupHasMatch) {
					currentGroup.style.display = 'none';
					if (currentColumns) currentColumns.style.display = 'none';
				}
				currentGroup = row;
				currentColumns = null;
				groupHasMatch = false;
				row.style.display = '';
			} else if (row.classList.contains('columns-row')) {
				currentColumns = row;
				row.style.display = '';
			} else if (row.classList.contains('meter-row')) {
				const match = row.textContent.toLowerCase().includes(filterText);
				row.style.display = match ? '' : 'none';
				if (match) {
					groupHasMatch = true;
					visibleMeterRowIndices.add(index);
				}
			}
		});

		// Final group check
		if (currentGroup && !groupHasMatch) {
			currentGroup.style.display = 'none';
			if (currentColumns) currentColumns.style.display = 'none';
		}

		// Second pass: handle spacer-row visibility
		rows.forEach((row, index) => {
			if (!row.classList.contains('spacer-row')) return;

			let hasVisibleBefore = false;
			for (let i = index - 1; i >= 0; i--) {
				const prevRow = rows[i];
				if (
					prevRow.classList.contains('group') ||
					prevRow.classList.contains('columns-row')
				) break;
				if (
					prevRow.classList.contains('meter-row') &&
					prevRow.style.display !== 'none'
				) {
					hasVisibleBefore = true;
					break;
				}
			}
			row.style.display = hasVisibleBefore ? '' : 'none';
		});
	});

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
