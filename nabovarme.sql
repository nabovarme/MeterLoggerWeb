# ************************************************************
# Sequel Pro SQL dump
# Version 5446
#
# https://www.sequelpro.com/
# https://github.com/sequelpro/sequelpro
#
# Host: 127.0.0.1 (MySQL 5.5.5-10.5.8-MariaDB-1:10.5.8+maria~focal-log)
# Database: nabovarme
# Generation Time: 2021-03-15 12:23:23 +0000
# ************************************************************


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;
SET NAMES utf8mb4;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;


# Dump of table accounts
# ------------------------------------------------------------

DROP TABLE IF EXISTS `accounts`;

CREATE TABLE `accounts` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `type` enum('payment','membership','charge') COLLATE utf8mb4_unicode_ci DEFAULT 'payment',
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT 0,
  `info` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT '',
  `price` float NOT NULL DEFAULT 1,
  `auto` tinyint(1) DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_idx` (`serial`,`payment_time`,`amount`,`price`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table accounts_auto
# ------------------------------------------------------------

DROP TABLE IF EXISTS `accounts_auto`;

CREATE TABLE `accounts_auto` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT 0,
  `info` varchar(512) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `transaction_id` varchar(1024) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `price` float NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`),
  UNIQUE KEY `transaction_id` (`transaction_id`) USING HASH
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table accounts_auto_payers_learned
# ------------------------------------------------------------

DROP TABLE IF EXISTS `accounts_auto_payers_learned`;

CREATE TABLE `accounts_auto_payers_learned` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `phone` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `comment` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table alarms
# ------------------------------------------------------------

DROP TABLE IF EXISTS `alarms`;

CREATE TABLE `alarms` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) NOT NULL DEFAULT 1,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `condition` longtext COLLATE utf8mb4_unicode_ci NOT NULL,
  `last_notification` int(11) DEFAULT NULL,
  `alarm_state` int(1) unsigned NOT NULL DEFAULT 0,
  `repeat` int(11) NOT NULL DEFAULT 0,
  `snooze` int(11) NOT NULL DEFAULT 0,
  `default_snooze` int(11) NOT NULL DEFAULT 1800,
  `snooze_auth_key` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `sms_notification` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `down_message` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `up_message` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `comment` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table command_queue
# ------------------------------------------------------------

DROP TABLE IF EXISTS `command_queue`;

CREATE TABLE `command_queue` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `function` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `param` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  `state` enum('sent','received','timeout') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'sent',
  `has_callback` tinyint(1) NOT NULL DEFAULT 0,
  `timeout` int(11) NOT NULL DEFAULT 0,
  `sent_count` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table log
# ------------------------------------------------------------

DROP TABLE IF EXISTS `log`;

CREATE TABLE `log` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `function` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `param` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table meter_groups
# ------------------------------------------------------------

DROP TABLE IF EXISTS `meter_groups`;

CREATE TABLE `meter_groups` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `group` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table meters
# ------------------------------------------------------------

DROP TABLE IF EXISTS `meters`;

CREATE TABLE `meters` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) DEFAULT 1,
  `type` enum('heat','water','electricity','aggregated','heat_supply','heat_sub') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'heat',
  `group` int(3) unsigned NOT NULL DEFAULT 0,
  `parent_serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `info` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `setup_value` float NOT NULL DEFAULT 0,
  `setup_hours` int(11) DEFAULT 0,
  `sw_version` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `key` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `valve_status` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `valve_installed` tinyint(1) NOT NULL DEFAULT 1,
  `last_updated` int(11) DEFAULT 0,
  `uptime` int(11) DEFAULT NULL,
  `reset_reason` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `ssid` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `rssi` int(8) DEFAULT NULL,
  `min_amount` float NOT NULL DEFAULT 0,
  `default_price` float NOT NULL DEFAULT 1,
  `email_notification` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `sms_notification` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `close_notification_time` int(11) DEFAULT 604800 COMMENT 'send notice this many seconds before we close (default 7 days)',
  `notification_state` int(1) unsigned NOT NULL DEFAULT 0,
  `notification_sent_at` float DEFAULT NULL,
  `wifi_status` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT 'disconnected',
  `wifi_set_ssid` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `wifi_set_pwd` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `ap_status` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `location_lat` decimal(12,8) DEFAULT NULL,
  `location_long` decimal(12,8) DEFAULT NULL,
  `comment` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table samples
# ------------------------------------------------------------

DROP TABLE IF EXISTS `samples`;

CREATE TABLE `samples` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `heap` int(11) unsigned DEFAULT NULL,
  `flow_temp` float DEFAULT NULL,
  `return_flow_temp` float DEFAULT NULL,
  `temp_diff` float DEFAULT NULL,
  `t3` float DEFAULT NULL,
  `flow` float DEFAULT NULL,
  `effect` float DEFAULT NULL,
  `hours` float DEFAULT NULL,
  `volume` float DEFAULT NULL,
  `energy` float DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`),
  KEY `unix_time` (`unix_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table samples_cache
# ------------------------------------------------------------

DROP TABLE IF EXISTS `samples_cache`;

CREATE TABLE `samples_cache` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `heap` int(11) unsigned DEFAULT NULL,
  `flow_temp` float DEFAULT NULL,
  `return_flow_temp` float DEFAULT NULL,
  `temp_diff` float DEFAULT NULL,
  `t3` float DEFAULT NULL,
  `flow` float DEFAULT NULL,
  `effect` float DEFAULT NULL,
  `hours` float DEFAULT NULL,
  `volume` float DEFAULT NULL,
  `energy` float DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table samples_calculated
# ------------------------------------------------------------

DROP TABLE IF EXISTS `samples_calculated`;

CREATE TABLE `samples_calculated` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `heap` int(11) unsigned DEFAULT NULL,
  `flow_temp` float DEFAULT NULL,
  `return_flow_temp` float DEFAULT NULL,
  `temp_diff` float DEFAULT NULL,
  `t3` float DEFAULT NULL,
  `flow` float DEFAULT NULL,
  `effect` float DEFAULT NULL,
  `hours` float DEFAULT NULL,
  `volume` float DEFAULT NULL,
  `energy` float DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table sms_auth
# ------------------------------------------------------------

DROP TABLE IF EXISTS `sms_auth`;

CREATE TABLE `sms_auth` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `cookie_token` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `session` tinyint(1) NOT NULL DEFAULT 0,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `auth_state` set('new','login','sms_code_sent','sms_code_verified','deny') COLLATE utf8mb4_unicode_ci DEFAULT 'new',
  `phone` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `sms_code` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `orig_uri` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `remote_host` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `user_agent` longtext COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table users
# ------------------------------------------------------------

DROP TABLE IF EXISTS `users`;

CREATE TABLE `users` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `password` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `admin_group` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `name` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `mail` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `phone` varchar(256) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `address` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `meter_id` int(255) DEFAULT NULL,
  `comment` varchar(256) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;



# Dump of table wifi_scan
# ------------------------------------------------------------

DROP TABLE IF EXISTS `wifi_scan`;

CREATE TABLE `wifi_scan` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `ssid` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `bssid` varchar(64) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `rssi` int(11) DEFAULT NULL,
  `channel` int(11) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`),
  KEY `ssid_idx` (`ssid`),
  KEY `unix_time_idx` (`unix_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;




/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;
/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
