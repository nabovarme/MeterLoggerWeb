document.addEventListener('DOMContentLoaded', async () => {
	const masterCheckbox = document.getElementById('alarmEnabled');
	const smsCheckbox    = document.getElementById('smsEnabled');
	const pushCheckbox   = document.getElementById('pushEnabled');
	const statusMsg      = document.getElementById('statusMsg');

	function showStatus(message, isError = false) {
		statusMsg.className = 'status-msg ' + (isError ? 'status-error' : 'status-success');
		statusMsg.textContent = message;
		statusMsg.style.display = 'block';

		setTimeout(() => {
			statusMsg.style.display = 'none';
		}, 3000);
	}

	async function loadSettings() {
		try {
			const res = await fetch('/api/notification_settings');
			const data = await res.json();

			if (!data.success) {
				throw new Error(data.error || 'Failed to load settings');
			}

			masterCheckbox.checked = Boolean(data.alarm_enabled);
			smsCheckbox.checked    = Boolean(data.sms_enabled);
			pushCheckbox.checked   = Boolean(data.push_enabled);
		} catch (err) {
			showStatus(err.message, true);
		}
	}

	async function saveSettings() {
		const payload = {
			alarm_enabled: masterCheckbox.checked ? 1 : 0,
			sms_enabled:   smsCheckbox.checked    ? 1 : 0,
			push_enabled:  pushCheckbox.checked   ? 1 : 0
		};

		try {
			const res = await fetch('/api/notification_settings', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(payload)
			});

			const data = await res.json();
			if (!data.success) throw new Error(data.error || 'Save failed');

			showStatus('Settings updated successfully');
		} catch (err) {
			showStatus(err.message, true);
			await loadSettings(); // Revert on failure
		}
	}

	masterCheckbox.addEventListener('change', saveSettings);
	smsCheckbox.addEventListener('change', saveSettings);
	pushCheckbox.addEventListener('change', saveSettings);

	await loadSettings();
});
