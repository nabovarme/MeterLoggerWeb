self.addEventListener('push', function(event) {
	if (!event.data) return;

	let payload = {};
	try {
		payload = event.data.json();
	} catch (e) {
		payload = { title: 'MeterLogger Alert', body: event.data.text() };
	}

	const options = {
		body: payload.body || 'New alert from MeterLogger',
		icon: payload.icon || '/android-chrome-192x192.png',
		badge: payload.badge || '/favicon-32x32.png',
		data: { url: payload.url || '/' },
		vibrate: [100, 50, 100]
	};

	event.waitUntil(
		self.registration.showNotification(payload.title || 'MeterLogger', options)
	);
});

self.addEventListener('notificationclick', function(event) {
	event.notification.close();
	const targetUrl = event.notification.data ? event.notification.data.url : '/';

	event.waitUntil(
		clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientList) {
			for (let i = 0; i < clientList.length; i++) {
				const client = clientList[i];
				if (client.url.includes(targetUrl) && 'focus' in client) {
					return client.focus();
				}
			}
			if (clients.openWindow) {
				return clients.openWindow(targetUrl);
			}
		})
	);
});
