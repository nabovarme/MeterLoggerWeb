const searchInput = document.getElementById('meterSearch');

function filterMeters() {
	const filter = searchInput.value.trim().toLowerCase();
	const rows = document.querySelectorAll('table.top tr');

	let currentGroupHeader = null;
	let currentColumnHeader = null;	// Track the column header row too
	let groupHasVisibleRows = false;

	rows.forEach(row => {
		const isGroupHeader = row.querySelector('span.default-group');
		const isColumnHeader = row.querySelector('span.default-bold');

		if (isGroupHeader) {
			// Before switching group, hide previous group and column headers if no visible rows
			if (currentGroupHeader && !groupHasVisibleRows) {
				currentGroupHeader.style.display = 'none';
				if (currentColumnHeader) {
					currentColumnHeader.style.display = 'none';
				}
			}
			// New group starts
			currentGroupHeader = row;
			groupHasVisibleRows = false;
			currentGroupHeader.style.display = '';
			currentColumnHeader = null; // Reset column header for new group
			return;
		}

		if (isColumnHeader) {
			// Track the column header row for current group
			currentColumnHeader = row;
			currentColumnHeader.style.display = '';
			return;
		}

		if (filter === '') {
			row.style.display = '';
			groupHasVisibleRows = true;
		} else {
			const text = row.textContent.toLowerCase();
			const match = text.includes(filter);
			row.style.display = match ? '' : 'none';
			if (match) groupHasVisibleRows = true;
		}
	});

	// After loop ends, hide last group headers if no visible rows
	if (currentGroupHeader && !groupHasVisibleRows) {
		currentGroupHeader.style.display = 'none';
		if (currentColumnHeader) {
			currentColumnHeader.style.display = 'none';
		}
	}
}

searchInput.addEventListener('input', filterMeters);

// Run filter once on load to show all rows
filterMeters();

// Focus input on any character keypress anywhere (except modifiers)
document.addEventListener('keydown', function(e) {
	if (!e.ctrlKey && !e.metaKey && !e.altKey && e.key.length === 1 && document.activeElement !== searchInput) {
		searchInput.focus();
	}
});
