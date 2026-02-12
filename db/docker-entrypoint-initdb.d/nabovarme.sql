/*M!999999\- enable the sandbox mode */ 
-- MariaDB dump 10.19  Distrib 10.5.29-MariaDB, for debian-linux-gnu (x86_64)
--
-- Host: db    Database: nabovarme
-- ------------------------------------------------------
-- Server version	10.5.28-MariaDB-ubu2004

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `_accounts_auto`
--

DROP TABLE IF EXISTS `_accounts_auto`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `_accounts_auto` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT 0,
  `info_row` varchar(512) NOT NULL DEFAULT '',
  `info_detail` varchar(512) NOT NULL DEFAULT '',
  `price` float NOT NULL DEFAULT 1,
  `phone` varchar(256) DEFAULT NULL,
  `state` enum('new','partially_parsed','parsed','accounted','ignored','error') DEFAULT 'new',
  `screenshot_row` longblob DEFAULT NULL,
  `screenshot_detail` longblob DEFAULT NULL,
  `info_row_hash` bigint(12) DEFAULT NULL,
  `info_detail_hash` bigint(12) DEFAULT NULL,
  `info_row_phash` varchar(512) DEFAULT NULL,
  `duplicate_count` int(11) DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_idx` (`serial`,`payment_time`,`amount`,`price`),
  UNIQUE KEY `unique_info_row_idx` (`info_row_hash`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=3416 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `_accounts_auto_payers_learned`
--

DROP TABLE IF EXISTS `_accounts_auto_payers_learned`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `_accounts_auto_payers_learned` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `phone` varchar(256) DEFAULT NULL,
  `comment` longtext DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `accounts`
--

DROP TABLE IF EXISTS `accounts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `accounts` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `type` enum('payment','membership','charge') DEFAULT 'payment',
  `serial` varchar(16) DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT 0,
  `info` varchar(256) DEFAULT '',
  `price` float NOT NULL DEFAULT 1,
  `auto` tinyint(1) DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_idx` (`serial`,`payment_time`,`amount`,`price`),
  KEY `serial_idx` (`serial`),
  KEY `accounts_serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=8027 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `accounts_auto`
--

DROP TABLE IF EXISTS `accounts_auto`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `accounts_auto` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT 0,
  `info` varchar(512) NOT NULL DEFAULT '',
  `transaction_id` varchar(1024) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `transaction_id` (`transaction_id`) USING HASH
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `accounts_auto_payers_learned`
--

DROP TABLE IF EXISTS `accounts_auto_payers_learned`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `accounts_auto_payers_learned` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `phone` varchar(256) DEFAULT NULL,
  `comment` longtext DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `accounts_log`
--

DROP TABLE IF EXISTS `accounts_log`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `accounts_log` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `username` varchar(64) NOT NULL,
  `admin_group` varchar(255) NOT NULL,
  `serial` varchar(16) DEFAULT NULL,
  `type` varchar(32) NOT NULL,
  `info` text DEFAULT NULL,
  `amount` float DEFAULT NULL,
  `price` float DEFAULT NULL,
  `remote_addr` varchar(45) NOT NULL,
  `user_agent` text NOT NULL,
  `unix_time` int(10) unsigned NOT NULL DEFAULT unix_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_serial_time` (`serial`,`unix_time`),
  KEY `idx_user_time` (`username`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=156 DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `alarm_templates`
--

DROP TABLE IF EXISTS `alarm_templates`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `alarm_templates` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `description` varchar(256) NOT NULL DEFAULT '',
  `condition` longtext NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1006 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `alarms`
--

DROP TABLE IF EXISTS `alarms`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `alarms` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) NOT NULL DEFAULT 1,
  `auto_id` int(11) unsigned DEFAULT NULL,
  `serial` varchar(16) DEFAULT NULL,
  `condition` longtext NOT NULL,
  `condition_error` longtext DEFAULT NULL,
  `last_notification` int(11) DEFAULT NULL,
  `alarm_state` int(1) unsigned NOT NULL DEFAULT 0,
  `repeat` int(11) NOT NULL DEFAULT 0,
  `alarm_count` int(11) NOT NULL DEFAULT 0,
  `exp_backoff_enabled` tinyint(1) NOT NULL DEFAULT 1,
  `snooze` int(11) NOT NULL DEFAULT 0,
  `default_snooze` int(11) NOT NULL DEFAULT 1800,
  `snooze_auth_key` varchar(64) NOT NULL DEFAULT '',
  `sms_notification` varchar(64) DEFAULT NULL,
  `down_message` longtext DEFAULT NULL,
  `up_message` longtext DEFAULT NULL,
  `comment` longtext DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `auto_id` (`auto_id`)
) ENGINE=InnoDB AUTO_INCREMENT=3315 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `alarms_auto`
--

DROP TABLE IF EXISTS `alarms_auto`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `alarms_auto` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) NOT NULL DEFAULT 1,
  `description` varchar(256) NOT NULL DEFAULT '',
  `condition` longtext NOT NULL,
  `down_message` longtext DEFAULT NULL,
  `up_message` longtext DEFAULT NULL,
  `repeat` int(11) NOT NULL DEFAULT 0,
  `default_snooze` int(11) NOT NULL DEFAULT 1800,
  `sms_notification` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `command_queue`
--

DROP TABLE IF EXISTS `command_queue`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `command_queue` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `function` varchar(256) DEFAULT NULL,
  `param` varchar(256) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  `state` enum('sent','received','timeout') NOT NULL DEFAULT 'sent',
  `has_callback` tinyint(1) NOT NULL DEFAULT 0,
  `timeout` int(11) NOT NULL DEFAULT 0,
  `sent_count` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=844941827 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `log`
--

DROP TABLE IF EXISTS `log`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `log` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) DEFAULT NULL,
  `function` varchar(256) DEFAULT NULL,
  `param` varchar(256) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=53629512 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meter_groups`
--

DROP TABLE IF EXISTS `meter_groups`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `meter_groups` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `group` varchar(256) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1000 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meters`
--

DROP TABLE IF EXISTS `meters`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `meters` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `enabled` tinyint(1) DEFAULT 1,
  `type` enum('heat','water','electricity','aggregated','heat_supply','heat_sub') NOT NULL DEFAULT 'heat',
  `group` int(3) unsigned NOT NULL DEFAULT 0,
  `parent_serial` varchar(16) DEFAULT NULL,
  `serial` varchar(16) DEFAULT NULL,
  `info` varchar(256) NOT NULL DEFAULT '',
  `setup_value` float NOT NULL DEFAULT 0,
  `setup_hours` int(11) DEFAULT 0,
  `sw_version` varchar(256) DEFAULT NULL,
  `key` varchar(32) DEFAULT NULL,
  `valve_status` varchar(256) DEFAULT NULL,
  `valve_installed` tinyint(1) NOT NULL DEFAULT 1,
  `last_updated` int(11) DEFAULT 0,
  `uptime` int(11) DEFAULT NULL,
  `reset_reason` varchar(255) DEFAULT NULL,
  `ssid` varchar(32) DEFAULT NULL,
  `rssi` int(8) DEFAULT NULL,
  `min_amount` float NOT NULL DEFAULT 0,
  `default_price` float NOT NULL DEFAULT 1,
  `email_notification` varchar(256) DEFAULT NULL,
  `sms_notification` varchar(256) DEFAULT NULL,
  `close_warning_threshold` int(11) DEFAULT 604800 COMMENT 'send notice this many seconds before we close (default 7 days)',
  `wifi_status` varchar(32) DEFAULT 'disconnected',
  `wifi_set_ssid` varchar(32) DEFAULT NULL,
  `wifi_set_pwd` varchar(64) DEFAULT NULL,
  `ap_status` varchar(32) DEFAULT NULL,
  `location_lat` decimal(12,8) DEFAULT NULL,
  `location_long` decimal(12,8) DEFAULT NULL,
  `chip_id` varchar(32) DEFAULT NULL,
  `flash_id` varchar(32) DEFAULT NULL,
  `flash_size` varchar(32) DEFAULT NULL,
  `ping_response_time` varchar(32) DEFAULT NULL,
  `ping_average_packet_loss` varchar(32) DEFAULT NULL,
  `disconnect_count` int(11) DEFAULT NULL,
  `comment` longtext DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=412 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meters_state`
--

DROP TABLE IF EXISTS `meters_state`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `meters_state` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) NOT NULL,
  `close_warning_threshold` int(11) DEFAULT 604800 COMMENT 'send notice this many seconds before we close (default 7 days)',
  `notification_state` tinyint(1) unsigned DEFAULT 0,
  `last_notification_sent_time` int(11) DEFAULT NULL,
  `last_paid_kwh_marker` float DEFAULT NULL,
  `last_close_warning_kwh_marker` float DEFAULT NULL,
  `kwh_remaining` float DEFAULT NULL,
  `time_remaining_hours` float DEFAULT NULL,
  `time_remaining_hours_string` varchar(32) DEFAULT '∞',
  `energy_last_day` float DEFAULT NULL,
  `avg_energy_last_day` float DEFAULT NULL,
  `latest_energy_reading` float DEFAULT NULL,
  `paid_kwh` float DEFAULT NULL,
  `method` varchar(32) DEFAULT NULL,
  `last_updated` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `serial` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=18725298 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples`
--

DROP TABLE IF EXISTS `samples`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `samples` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) DEFAULT NULL,
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
  `is_spike` tinyint(1) DEFAULT 0,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`),
  KEY `serial_time_spike_idx` (`serial`,`unix_time`,`is_spike`),
  KEY `spike_serial_unix_time_idx` (`serial`,`is_spike`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=814444227 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples_cache`
--

DROP TABLE IF EXISTS `samples_cache`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `samples_cache` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) DEFAULT NULL,
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
  `is_spike` tinyint(1) DEFAULT 0,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`),
  KEY `spike_serial_unix_time_idx` (`serial`,`is_spike`,`unix_time`),
  KEY `samples_cache_serial_unix_id_idx` (`serial`,`unix_time`,`id`)
) ENGINE=InnoDB AUTO_INCREMENT=814194788 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples_daily`
--

DROP TABLE IF EXISTS `samples_daily`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `samples_daily` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) DEFAULT NULL,
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
) ENGINE=InnoDB AUTO_INCREMENT=773877807 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples_hourly`
--

DROP TABLE IF EXISTS `samples_hourly`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `samples_hourly` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(12) DEFAULT NULL,
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
) ENGINE=InnoDB AUTO_INCREMENT=973774917 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `sms_auth`
--

DROP TABLE IF EXISTS `sms_auth`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `sms_auth` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `cookie_token` varchar(256) DEFAULT NULL,
  `session` tinyint(1) NOT NULL DEFAULT 0,
  `serial` varchar(16) DEFAULT NULL,
  `auth_state` set('new','login','sms_code_sent','sms_code_verified','deny') DEFAULT 'new',
  `phone` varchar(64) DEFAULT NULL,
  `sms_code` varchar(256) DEFAULT NULL,
  `remote_host` varchar(256) DEFAULT NULL,
  `orig_uri` longtext DEFAULT NULL,
  `user_agent` longtext DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=2338070 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `sms_messages`
--

DROP TABLE IF EXISTS `sms_messages`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `sms_messages` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `direction` enum('sent','received') CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL,
  `phone` varchar(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL,
  `message` text CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci NOT NULL,
  `unix_time` int(11) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1961107 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `users`
--

DROP TABLE IF EXISTS `users`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `users` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(256) NOT NULL DEFAULT '',
  `password` varchar(256) NOT NULL DEFAULT '',
  `admin_group` varchar(256) DEFAULT NULL,
  `name` varchar(256) NOT NULL DEFAULT '',
  `mail` varchar(256) NOT NULL DEFAULT '',
  `phone` varchar(256) NOT NULL DEFAULT '',
  `address` varchar(256) DEFAULT NULL,
  `meter_id` int(255) DEFAULT NULL,
  `comment` varchar(256) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=102 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `wifi_scan`
--

DROP TABLE IF EXISTS `wifi_scan`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `wifi_scan` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `ssid` varchar(64) DEFAULT NULL,
  `ssid_raw` varbinary(64) DEFAULT NULL,
  `bssid` varchar(64) DEFAULT NULL,
  `rssi` int(11) DEFAULT NULL,
  `channel` int(11) DEFAULT NULL,
  `auth_mode` varchar(16) DEFAULT NULL,
  `pairwise_cipher` varchar(16) DEFAULT NULL,
  `group_cipher` varchar(16) DEFAULT NULL,
  `phy_11b` varchar(1) DEFAULT NULL,
  `phy_11g` varchar(1) DEFAULT NULL,
  `phy_11n` varchar(1) DEFAULT NULL,
  `wps` varchar(1) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`),
  KEY `ssid_idx` (`ssid`),
  KEY `unix_time_idx` (`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=451495131 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-01-05 23:39:49
