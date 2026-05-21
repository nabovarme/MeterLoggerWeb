let smsDebounceTimeout = null;
const SCROLL_KEY = 'sms_sent_scroll';

// =========================
// SCROLL (global manager)
// =========================
bindScrollPersistence(SCROLL_KEY);
enableAutoRestore(SCROLL_KEY);

// Cache the tbody element globally once
const tbody = document.querySelector('#sms_table tbody');

// =======================================================
// Event Delegation outside loadSMS()
// This runs exactly ONCE, completely eliminating the memory leak.
// =======================================================
if (tbody) {
	// we add event listener to the parent tbody that intercepts the click.
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
}

async function loadSMS() {
	try {
		const resp = await fetch('/api/sms_sent');
		if (!resp.ok) {
			throw new Error(`HTTP error! status: ${resp.status}`);
		}

		const data = await resp.json();
		if (!tbody) return;

		// 🚀 OPTIMIZATION: Build the table off-screen in memory.
		// This prevents the browser from laggy row-by-row layout thrashing.
		const fragment = document.createDocumentFragment();

		const params = new URLSearchParams(window.location.search);
		const initialSearch = (params.get('q') || '').toLowerCase();

		data.forEach((row, index) => {
			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';
	
			// Kept native zebra striping inline here during row creation
			tr.style.background = (index % 2 === 0) ? '#FFFFFF' : '#EEEEEE';

			// The user sees the formatted E164 string, but the hidden span contains the raw DB string for searching
			const phoneLink = `
				<a href="#" class="phone-link" style="white-space: nowrap;" data-phone="${row.phone}">${row.phone_e164}</a>
				<span style="display: none;">${row.phone}</span>
			`;

			let messageHTML = row.message || '';

			// =======================================================
			// 1. Parse Same-Server URLs
			// =======================================================
			const currentHostname = window.location.hostname;
	
			messageHTML = messageHTML.replace(/(https?:\/\/[^\s]+)/g, (match) => {
				let cleanUrl = match;
				let trailingPunctuation = '';
		
				// Strip common trailing punctuation so it doesn't break the URL
				if (/[.,;!?)]$/.test(match)) {
					trailingPunctuation = match.slice(-1);
					cleanUrl = match.slice(0, -1);
				}

				try {
					const parsedUrl = new URL(cleanUrl);
					// Only wrap in an <a> tag if the hostnames match
					if (parsedUrl.hostname === currentHostname) {
						// Use target="_blank" if you want these to open in a new tab
						return `<a href="${cleanUrl}">${cleanUrl}</a>${trailingPunctuation}`;
					}
				} catch (e) {
					// Catch block safely ignores invalid URLs parsed by the regex
				}
		
				// Return original text if it's not the same server or is invalid
				return match;
			});

			// =======================================================
			// 2. Parse Serial Numbers
			// =======================================================
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
		// Sync search state with freshly loaded data
		// =======================================================
		const searchInput = document.getElementById('smsSentSearch');
		const currentQuery = searchInput ? searchInput.value.toLowerCase() : '';

		if (currentQuery) {
			// If the user typed *while* the page was fetching, apply it instantly now!
			filterRows(currentQuery);
		} else if (initialSearch) {
			// Fallback to URL state if input is untouched but URL has a query
			filterRows(initialSearch);
		}

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

// =======================================================
// debounce the local UI DOM filter instead of hammering the API
// =======================================================
function debounceFilter(query) {
	clearTimeout(smsDebounceTimeout);

	smsDebounceTimeout = setTimeout(() => {
		filterRows(query.toLowerCase());

		// Force layout evaluation so global scroll manager detects the row height changes
		window.dispatchEvent(new Event('scroll'));
	}, 150);
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
		
		// Run instant client-side table sorting instead of triggering loadSMS() network calls
		debounceFilter(val);
	});
}

// --- Initial load ---
loadSMS();
