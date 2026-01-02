async function loadSMS() {
	try {
		const resp = await fetch('/api/sms_sent');
		if (!resp.ok) throw new Error(`HTTP error! status: ${resp.status}`);
		const data = await resp.json();

		const tbody = document.querySelector('#sms_table tbody');
		tbody.innerHTML = ''; // clear existing rows

		for (const row of data) {
			const tr = document.createElement('tr');
			tr.align = 'left';
			tr.valign = 'top';

			// Create phone link
			const phoneLink = `<a href="#" class="phone-link" data-phone="${row.phone}">${row.phone}</a>`;

			tr.innerHTML = `
				<td align="left">${phoneLink}</td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.message}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.direction}</span></td>
				<td>&nbsp;</td>
				<td align="left"><span class="default">${row.time}</span></td>
			`;

			tbody.appendChild(tr);
		}

		// Add click handlers for all phone links
		document.querySelectorAll('.phone-link').forEach(link => {
			link.addEventListener('click', function (e) {
				e.preventDefault();
				const phone = this.dataset.phone;
				const last8 = phone.slice(-8); // only last 8 digits
				const input = document.getElementById('smsSentSearch');
				input.value = last8;
				filterRows(last8.toLowerCase()); // global filter function
				input.focus();
			});
		});

		// Update row colors after load
		const rows = tbody.querySelectorAll('tr');
		rows.forEach((row, index) => {
			row.style.background = (index % 2 === 0) ? '#FFF' : '#EEE';
		});

	} catch (err) {
		console.error('Failed to load SMS list:', err);
	}
}

// --- Initial load ---
loadSMS();
