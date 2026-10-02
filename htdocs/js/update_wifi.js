document.addEventListener("DOMContentLoaded", async () => {
	const params = new URLSearchParams(window.location.search);
	const serial = params.get('serial');
	
	const statusMsg = document.getElementById('statusMsg');
	const formCard = document.getElementById('formCard');
	const form = document.getElementById('wifi-update-form');
	const btn = document.getElementById('update-btn');

	// Helper to handle inline status alerts
	function showStatus(message, type = 'info') {
		statusMsg.className = `status-msg status-${type}`;
		statusMsg.textContent = message;
		statusMsg.style.display = 'block';
	}
	
	if (!serial) {
		showStatus('Error: No serial provided.', 'error');
		return;
	}
	
	// ==========================================
	// 1. Fetch and Populate Meter Info
	// ==========================================
	try {
		const fetchUrl = '/api/wifi_update?' + params.toString();
		const res = await fetch(fetchUrl);
		const data = await res.json();
		
		if (data.status === 'ok') {
			statusMsg.style.display = 'none'; // Hide loading state
			document.title = data.info + ' MeterLogger';
			
			document.getElementById('display-info').innerText = data.info;
			document.getElementById('display-serial').innerText = 'serial ' + data.serial;
			
			document.getElementById('input-serial').value = data.serial;
			document.getElementById('input-ssid').value = data.ssid || '';
			document.getElementById('input-password').value = data.password || '';
			
			formCard.style.display = 'block'; // Show form card
		} else {
			showStatus('Access Denied: ' + (data.error || 'Unauthorized'), 'error');
		}
	} catch (err) {
		console.error(err);
		showStatus('Network error communicating with server.', 'error');
	}

	// ==========================================
	// 2. Submit Form Updates via API
	// ==========================================
	form.addEventListener('submit', async (e) => {
		e.preventDefault(); 
		
		statusMsg.style.display = 'none';
		btn.textContent = 'Updating...';
		btn.disabled = true;
		
		const payload = {
			serial: document.getElementById('input-serial').value,
			ssid: document.getElementById('input-ssid').value,
			password: document.getElementById('input-password').value
		};
		
		try {
			const res = await fetch('/api/wifi_update', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(payload)
			});
			
			const data = await res.json();
			
			if (data.status === 'ok') {
				showStatus('WiFi credentials successfully sent to meter queue.', 'success');
				btn.textContent = 'Updated';
				
				// Hide success message automatically after 5 seconds
				setTimeout(() => {
					if (statusMsg.className.includes('status-success')) {
						statusMsg.style.display = 'none';
					}
				}, 5000);
			} else {
				showStatus('Failed: ' + (data.error || 'Unknown error'), 'error');
				btn.textContent = 'Update';
			}
		} catch (err) {
			console.error(err);
			showStatus('Network error communicating with server.', 'error');
			btn.textContent = 'Update';
		} finally {
			btn.disabled = false;
		}
	});
});
