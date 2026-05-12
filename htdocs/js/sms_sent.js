let smsDebounceTimeout = null;

async function loadSMS() {
	try {
		const resp = await fetch('/api/sms_sent');
		if (!resp.ok) {
			throw new Error(`HTTP error! status: ${resp.status}`);
		}

		const data = await resp.json();
		const tbody = document.querySelector('#sms_table tbody');
		tbody.innerHTML = ''; // clear existing rows

		// =========================
		// URL STATE (READ)
		// =========================
		const params = new URLSearchParams(window.location.search);
		const search = (params.get('q') || '').toLowerCase();

		for (const row of data) {

			// optional filter (phone + message + direction)
			if (search) {
				const text = `${row.phone || ''} ${row.message || ''} ${row.direction || ''}`.toLowerCase();
				if (!text.includes(search)) continue;
			}

			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';

			// --- Phone link ---
			const phoneLink = `
				<a 
					href="#" 
					class="phone-link" 
					data-phone="${row.phone}"
				>
					${row.phone}
				</a>
			`;

			// --- Convert all "(number)" patterns in message to clickable links ---
			let messageHTML = row.message;

			// Replace every "(digits)" with "(<a href=...>digits</a>)"
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

			tbody.appendChild(tr);
		}

		// Add click handlers for phone links
		document.querySelectorAll('.phone-link').forEach(link => {
			link.addEventListener('click', function (e) {
				e.preventDefault();

				const last8 = this.dataset.phone.slice(-8);
				const input = document.getElementById('smsSentSearch');

				if (input) {
					input.value = last8;
					updateURL(last8);
					debounceReload();
					filterRows(last8.toLowerCase());
					input.focus();
				}
			});
		});

		// Update row colors
		const rows = tbody.querySelectorAll('tr');
		rows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
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
