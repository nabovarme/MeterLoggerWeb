// htdocs/js/push_notifications.js

/**
 * Converts a Base64 VAPID public key into a Uint8Array required by PushManager.
 */
function urlBase64ToUint8Array(base64String) {
	const padding = '='.repeat((4 - base64String.length % 4) % 4);
	const base64 = (base64String + padding).replace(/\-/g, '+').replace(/_/g, '/');
	const rawData = window.atob(base64);
	const outputArray = new Uint8Array(rawData.length);
	for (let i = 0; i < rawData.length; ++i) {
		outputArray[i] = rawData.charCodeAt(i);
	}
	return outputArray;
}

/**
 * Registers the Service Worker, requests notification permission, and sends subscription details to Perl API.
 * @param {string} serial - Target meter serial number
 * @param {string} vapidPublicKey - Application server VAPID public key
 * @returns {Promise<boolean>} Success state
 */
async function registerPushSubscription(serial, vapidPublicKey) {
	if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
		console.warn("Web Push notifications are not supported by this browser.");
		return false;
	}

	try {
		// 1. Register service worker at web root
		const registration = await navigator.serviceWorker.register('/js/service-worker.js', { scope: '/' });
		await navigator.serviceWorker.ready;

		// 2. Request user notification permission
		const permission = await Notification.requestPermission();
		if (permission !== 'granted') {
			console.warn("Notification permission denied by user.");
			return false;
		}

		// 3. Fetch existing subscription or create a new one
		let subscription = await registration.pushManager.getSubscription();
		if (!subscription) {
			subscription = await registration.pushManager.subscribe({
				userVisibleOnly: true,
				applicationServerKey: urlBase64ToUint8Array(vapidPublicKey)
			});
		}

		const subJson = subscription.toJSON();

		// 4. Post payload to Apache /api/subscribe_push handler
		const response = await fetch('/api/subscribe_push', {
			method: 'POST',
			headers: { 
				'Content-Type': 'application/json',
				'Cache-Control': 'no-cache'
			},
			body: JSON.stringify({
				serial: serial,
				endpoint: subJson.endpoint,
				p256dh: subJson.keys.p256dh,
				auth: subJson.keys.auth
			})
		});

		if (!response.ok) {
			throw new Error(`API returned HTTP ${response.status}`);
		}

		const result = await response.json();
		return result.success === 1;

	} catch (err) {
		console.error("Failed to register Web Push subscription:", err);
		return false;
	}
}

/**
 * Helper to inspect current notification state and update UI button accordingly.
 */
async function checkPushPermissionState(buttonId) {
	const btn = document.getElementById(buttonId);
	if (!btn) return;

	if (!('Notification' in window) || !('serviceWorker' in navigator)) {
		btn.disabled = true;
		btn.innerText = 'Push Unsupported';
		return;
	}

	if (Notification.permission === 'granted') {
		btn.innerText = 'Push Active';
		btn.classList.add('btn-active');
	} else if (Notification.permission === 'denied') {
		btn.disabled = true;
		btn.innerText = 'Push Blocked in Browser';
	}
}
