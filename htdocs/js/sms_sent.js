let smsDebounceTimeout = null;

const SCROLL_KEY = 'sms_sent_scroll';

// =========================
// SCROLL (global manager)
// =========================
bindScrollPersistence(SCROLL_KEY);
enableAutoRestore(SCROLL_KEY);

async function loadSMS() {
	try {
		const resp = await fetch('/api/sms_sent');
		if (!resp.ok) {
			throw new Error(`HTTP error! status: ${resp.status}`);
		}

		const data = await resp.json();
		const tbody = document.querySelector('#sms_table tbody');
		if (!tbody) return;

		// 🚀 OPTIMIZATION: Build the table off-screen in memory.
		// This prevents the browser from laggy row-by-row layout thrashing.
		const fragment = document.createDocumentFragment();

		const params = new URLSearchParams(window.location.search);
		const initialSearch = (params.get('q') || '').toLowerCase();

		data.forEach((row) => {
			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';

			// The user sees the formatted E164 string, but the hidden span contains the raw DB string for searching
			const phoneLink = `
				<a href="#" class="phone-link" style="white-space: nowrap;" data-phone="${row.phone}">${row.phone_e164}</a>
				<span style="display: none;">${row.phone}</span>
			`;

			// Replace "(digits)" patterns with serial detail links
			let messageHTML = row.message || '';
			messageHTML = messageHTML.replace(/\((\d+)\)/g, (_, serial) => {
				return `(<a href="/detail_acc.epl?serial=${serial}">${serial}</a>)`;
			});

			tr.innerHTML = `
				<td align="left">${phoneLink}</td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${messageHTML}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.direction}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.time}</span></td>
			`;

			fragment.appendChild(tr);
		});

		// Clear existing rows and drop the entire fragment into the DOM at once
		tbody.innerHTML = '';
		tbody.appendChild(fragment);

		// =======================================================
		// RACE CONDITION FIX: Sync search state with freshly loaded data
		// =======================================================
		const searchInput = document.getElementById('smsSentSearch');
		const currentQuery = searchInput ? searchInput.value.toLowerCase() : '';

		if (currentQuery) {
			// If the user typed *while* the page was fetching, apply it instantly now!
			filterRows(currentQuery);
		} else if (initialSearch) {
			// Fallback to URL state if input is untouched but URL has a query
			filterRows(initialSearch);
		} else {
			// Apply native zebra striping if no search query exists yet
			const rows = tbody.querySelectorAll('tr');
			rows.forEach((row, index) => {
				row.style.background = (index % 2 === 0) ? '#FFFFFF' : '#EEEEEE';
			});
		}

		// 🚀 OPTIMIZATION: Event Delegation
		// Instead of adding thousands of individual event listeners to every row,
		// we add ONE listener to the parent tbody that intercepts the click.
		tbody.addEventListener('click', function (e) {
			const targetLink = e.target.closest('.phone-link');
			if (!targetLink) return;

			e.preventDefault();
	
			const phone = targetLink.dataset.phone;
			const input = document.getElementById('smsSentSearch');

			if (input && phone) {
				input.value = phone;
				if (typeof updateURL === 'function') {
					updateURL(phone);
				}
				filterRows(phone.toLowerCase());
				input.focus();
			}
	});

	} catch (err) {
		console.error('Failed to load SMS list:', err);
	}
}

// =========================
// URL STATE HELPERS
// =========================

function updateURL(value) {
	const p = new URLSearchParams(window.location.search);

	if (value) p.set('q', value);
	else p.delete('q');

	history.replaceState(null, '', `${window.location.pathname}?${p.toString()}`);
}

// =========================
// DEBOUNCE RELOAD
// =========================

function debounceReload() {
	clearTimeout(smsDebounceTimeout);

	smsDebounceTimeout = setTimeout(() => {
		loadSMS();
	}, 300);
}

// =========================
// INIT EVENT BINDING
// =========================

const input = document.getElementById('smsSentSearch');

if (input) {
	// restore from URL
	const params = new URLSearchParams(window.location.search);
	input.value = params.get('q') || '';

	input.addEventListener('input', () => {
		const val = input.value;

		updateURL(val);
		debounceReload();
	});
}

// --- Initial load ---
loadSMS();
