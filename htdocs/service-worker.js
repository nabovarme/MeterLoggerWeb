self.addEventListener('push', function(event) {
	if (!event.data) return;

	let payload = {};
	try {
		payload = event.data.json();
	} catch (e) {
		payload = { title: 'MeterLogger Alert', body: event.data.text() };
	}

	const tag = payload.tag || 'meter-alarm-default';

	const options = {
		body: payload.body || 'New alert from MeterLogger',
		icon: payload.icon || '/android-chrome-192x192.png',
		badge: payload.badge || '/favicon-32x32.png',
		image: payload.image,
		tag: tag, // Overwrites previous notifications with same tag
		renotify: payload.renotify !== undefined ? payload.renotify : true, // Dings/vibrates again when replaced
		requireInteraction: payload.requireInteraction,
		vibrate: payload.vibrate || [100, 50, 100],
		data: { 
			url: payload.url || '/',
			actionUrls: {}
		}
	};

	// Map action buttons securely
	if (payload.actions && Array.isArray(payload.actions)) {
		options.actions = payload.actions.map(actionObj => {
			if (actionObj.url) {
				options.data.actionUrls[actionObj.action] = actionObj.url;
			}
			return { 
				action: actionObj.action, 
				title: actionObj.title, 
				icon: actionObj.icon 
			};
		});
	}

	event.waitUntil(
		self.registration.getNotifications({ tag: tag }).then(existingNotifications => {
			// Explicitly close any previous active notification sharing this tag
			existingNotifications.forEach(notification => notification.close());

			return self.registration.showNotification(payload.title || 'MeterLogger', options);
		})
	);
});

self.addEventListener('notificationclick', function(event) {
	event.notification.close();

	// Default to the main notification URL
	let targetUrl = event.notification.data ? event.notification.data.url : '/';

	// If the user clicked a specific action button, override the targetUrl
	if (event.action && event.notification.data && event.notification.data.actionUrls) {
		if (event.notification.data.actionUrls[event.action]) {
			targetUrl = event.notification.data.actionUrls[event.action];
		}
	}

	event.waitUntil(
		clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientList) {
			for (let i = 0; i < clientList.length; i++) {
				const client = clientList[i];
				// Focus the existing tab if it's already open
				if (client.url.includes(targetUrl) && 'focus' in client) {
					return client.focus();
				}
			}
			// Otherwise, open a new window/tab
			if (clients.openWindow) {
				return clients.openWindow(targetUrl);
			}
		})
	);
});
