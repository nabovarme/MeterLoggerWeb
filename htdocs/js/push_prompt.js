document.addEventListener('DOMContentLoaded', function () {
	// 1. Basic feature and permission support checks
	if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) {
		return;
	}

	if (Notification.permission === 'denied') {
		return;
	}

	const dismissedAt = localStorage.getItem('push_prompt_dismissed');
	if (dismissedAt) {
		const daysSinceDismissed = (Date.now() - parseInt(dismissedAt, 10)) / (1000 * 60 * 60 * 24);
		if (daysSinceDismissed < 7) {
			return;
		}
	}

	// 2. Inject the Banner HTML synchronously into the DOM
	const containerHtml = `
		<div id="pushPromptContainer" style="position:fixed; bottom:20px; right:20px; left:20px; max-width:420px; margin:0 auto; background:#fff; border:1px solid #ccc; box-shadow:0 8px 24px rgba(0,0,0,0.15); border-radius:10px; padding:16px; z-index:9999; font-family:-apple-system, BlinkMacSystemFont, sans-serif; display:none;">
			<div style="font-weight:bold; font-size:15px; margin-bottom:8px; color:#222;">Enable Push Notifications?</div>
			<div style="font-size:13px; color:#555; margin-bottom:12px; line-height:1.4;">Get instant alert updates directly on this device when alarms trigger or resolve.</div>
			<div style="display:flex; justify-content:flex-end; gap:10px;">
				<button id="pushPromptDismiss" style="padding:8px 16px; border-radius:6px; border:none; cursor:pointer; background:#eee; font-weight:bold; color:#333; font-size:13px;">Not Now</button>
				<button id="pushPromptEnable" style="padding:8px 16px; border-radius:6px; border:none; cursor:pointer; background:#007aff; color:#fff; font-weight:bold; font-size:13px;">Enable</button>
			</div>
		</div>
	`;
	document.body.insertAdjacentHTML('beforeend', containerHtml);

	const container = document.getElementById('pushPromptContainer');
	const enableBtn = document.getElementById('pushPromptEnable');
	const dismissBtn = document.getElementById('pushPromptDismiss');

	// 3. Attach shielded click handlers for gesture activation
	enableBtn.addEventListener('click', function (event) {
		event.preventDefault();
		event.stopImmediatePropagation();

		const btn = this;

		const handleResult = function (permission) {
			btn.disabled = true;
			btn.textContent = 'Enabling...';

			if (permission === 'granted') {
				subscribeUserToPush().then(() => {
					container.remove();
				}).catch(err => {
					console.error('[Push Prompt] Subscribe failed:', err);
					btn.disabled = false;
					btn.textContent = 'Enable';
				});
			} else {
				container.remove();
			}
		};

		try {
			const promise = Notification.requestPermission(handleResult);
			if (promise && typeof promise.then === 'function') {
				promise.then(handleResult).catch(err => console.error('Promise Error:', err));
			}
		} catch (err) {
			console.error('Sync Error:', err);
		}
	});

	dismissBtn.addEventListener('click', function (event) {
		event.preventDefault();
		event.stopImmediatePropagation();
		localStorage.setItem('push_prompt_dismissed', Date.now().toString());
		container.remove();
	});

	// 4. Background check: Only render prompt if no active subscription exists
	navigator.serviceWorker.getRegistration().then(registration => {
		if (registration && registration.pushManager) {
			return registration.pushManager.getSubscription();
		}
		return null;
	}).then(existingSub => {
		if (!existingSub) {
			container.style.display = 'block';
		}
	}).catch(e => {
		console.warn('[Push Prompt] Status check error:', e);
		container.style.display = 'block';
	});
});

async function subscribeUserToPush() {
	let registration = await navigator.serviceWorker.getRegistration();
	if (!registration) {
		registration = await navigator.serviceWorker.register('/service-worker.js');
	}
	await navigator.serviceWorker.ready;

	const response = await fetch('/api/vapid_key');
	if (!response.ok) throw new Error('Failed to retrieve VAPID public key');

	const data = await response.json();
	if (!data.success || !data.public_key) {
		throw new Error(data.error || 'Server did not return a valid VAPID public key');
	}

	const convertedKey = urlBase64ToUint8Array(data.public_key);
	const subscription = await registration.pushManager.subscribe({
		userVisibleOnly: true,
		applicationServerKey: convertedKey
	});

	const subJson = subscription.toJSON();
	await fetch('/api/subscribe_push', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({
			endpoint: subJson.endpoint,
			p256dh: subJson.keys ? subJson.keys.p256dh : '',
			auth: subJson.keys ? subJson.keys.auth : ''
		})
	});
}

function urlBase64ToUint8Array(base64String) {
	const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
	const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
	const rawData = window.atob(base64);
	const outputArray = new Uint8Array(rawData.length);
	for (let i = 0; i < rawData.length; ++i) {
		outputArray[i] = rawData.charCodeAt(i);
	}
	return outputArray;
}
