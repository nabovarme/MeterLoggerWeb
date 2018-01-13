-- MySQL dump 10.13  Distrib 5.5.55, for debian-linux-gnu (x86_64)
--
-- Host: localhost    Database: nabovarme
-- ------------------------------------------------------
-- Server version	5.5.55-0+deb8u1

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `accounts`
--

DROP TABLE IF EXISTS `accounts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `accounts` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `payment_time` int(11) DEFAULT NULL,
  `amount` float NOT NULL DEFAULT '0',
  `info` varchar(256) NOT NULL DEFAULT '',
  `price` float NOT NULL DEFAULT '1',
  PRIMARY KEY (`id`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=429 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8 */ ;
/*!50003 SET character_set_results = utf8 */ ;
/*!50003 SET collation_connection  = utf8_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = '' */ ;
DELIMITER ;;
/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `accounts_insert_set_payment_time` BEFORE INSERT ON `accounts` FOR EACH ROW if (new.payment_time is null)
then 
	SET new.payment_time = UNIX_TIMESTAMP(NOW());
end if */;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8 */ ;
/*!50003 SET character_set_results = utf8 */ ;
/*!50003 SET collation_connection  = utf8_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = '' */ ;
DELIMITER ;;
/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `command_queue_insert_after` AFTER INSERT ON `accounts` FOR EACH ROW if (new.amount > 0)
then 
	INSERT INTO command_queue (`serial`, `function`, `param`, `unix_time`) 
	VALUES (new.`serial`, 'open_until', ((SELECT SUM(amount/price) AS paid_kwh FROM accounts WHERE serial = new.`serial`) + (SELECT meters.last_energy FROM meters WHERE meters.serial = new.`serial`)), UNIX_TIMESTAMP(NOW()));
end if */;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Table structure for table `alarms`
--

DROP TABLE IF EXISTS `alarms`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `alarms` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `condition` varchar(256) NOT NULL DEFAULT '',
  `last_notification` int(11) DEFAULT NULL,
  `alarm_state` int(1) unsigned NOT NULL DEFAULT '0',
  `repeat` int(11) NOT NULL DEFAULT '0',
  `sms_notification` varchar(64) DEFAULT NULL,
  `down_message` mediumtext,
  `up_message` mediumtext,
  `comment` mediumtext,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=24 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `command_queue`
--

DROP TABLE IF EXISTS `command_queue`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `command_queue` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `function` varchar(256) DEFAULT NULL,
  `param` varchar(256) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meter_groups`
--

DROP TABLE IF EXISTS `meter_groups`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `meter_groups` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `group` varchar(256) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1000 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `meters`
--

DROP TABLE IF EXISTS `meters`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `meters` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `type` int(3) unsigned NOT NULL DEFAULT '0',
  `group` int(3) unsigned NOT NULL DEFAULT '0',
  `serial` varchar(16) DEFAULT NULL,
  `info` varchar(256) NOT NULL DEFAULT '',
  `last_energy` float NOT NULL DEFAULT '0',
  `sw_version` varchar(256) DEFAULT NULL,
  `key` varchar(32) DEFAULT NULL,
  `valve_status` varchar(256) DEFAULT NULL,
  `last_updated` int(11) DEFAULT NULL,
  `uptime` int(11) DEFAULT NULL,
  `ssid` varchar(32) DEFAULT NULL,
  `rssi` int(8) DEFAULT NULL,
  `min_amount` float NOT NULL DEFAULT '0',
  `default_price` float NOT NULL DEFAULT '1',
  `email_notification` varchar(256) DEFAULT NULL,
  `sms_notification` varchar(64) DEFAULT NULL,
  `notification_state` int(1) unsigned NOT NULL DEFAULT '0',
  `notification_sent_at` float DEFAULT NULL,
  `wifi_status` varchar(32) DEFAULT 'disconnected',
  `wifi_set_ssid` varchar(32) DEFAULT NULL,
  `wifi_set_pwd` varchar(64) DEFAULT NULL,
  `ap_status` varchar(32) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_idx` (`serial`)
) ENGINE=InnoDB AUTO_INCREMENT=158 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `samples`
--

DROP TABLE IF EXISTS `samples`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
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
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=44019638 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = utf8 */ ;
/*!50003 SET character_set_results = utf8 */ ;
/*!50003 SET collation_connection  = utf8_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = '' */ ;
DELIMITER ;;
/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `samples_insert_after` AFTER INSERT ON `samples` FOR EACH ROW INSERT INTO samples_cache (`serial`, `heap`, `flow_temp`, `return_flow_temp`, `temp_diff`, `t3`, `flow`, `effect`, `hours`, `volume`, `energy`, `unix_time`) 
	VALUES (new.`serial`, new.`heap`, new.`flow_temp`, new.`return_flow_temp`, new.`temp_diff`, new.`t3`, new.`flow`, new.`effect`, new.`hours`, new.`volume`, new.`energy`, new.`unix_time`) */;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Table structure for table `samples_cache`
--

DROP TABLE IF EXISTS `samples_cache`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
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
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=44018952 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `sms_auth`
--

DROP TABLE IF EXISTS `sms_auth`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `sms_auth` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `cookie_token` varchar(256) DEFAULT NULL,
  `session` tinyint(1) NOT NULL DEFAULT '0',
  `serial` varchar(16) DEFAULT NULL,
  `auth_state` set('new','login','sms_code_sent','sms_code_verified','deny') DEFAULT 'new',
  `phone` varchar(64) DEFAULT NULL,
  `sms_code` varchar(256) DEFAULT NULL,
  `orig_uri` mediumtext,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=4829 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `ticket_secrets`
--

DROP TABLE IF EXISTS `ticket_secrets`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `ticket_secrets` (
  `sec_version` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `sec_data` text NOT NULL,
  UNIQUE KEY `sec_version` (`sec_version`)
) ENGINE=MyISAM AUTO_INCREMENT=2 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `tickets`
--

DROP TABLE IF EXISTS `tickets`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `tickets` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `ticket_hash` varchar(256) NOT NULL DEFAULT '',
  `ts` int(11) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `users`
--

DROP TABLE IF EXISTS `users`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `users` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(255) NOT NULL DEFAULT '',
  `password` varchar(255) NOT NULL DEFAULT '',
  `admin` tinyint(1) DEFAULT NULL,
  `name` varchar(255) NOT NULL DEFAULT '',
  `mail` varchar(255) NOT NULL DEFAULT '',
  `phone` varchar(255) NOT NULL DEFAULT '',
  `address` varchar(255) DEFAULT NULL,
  `meter_id` int(255) DEFAULT NULL,
  `comment` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=61 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `wifi_scan`
--

DROP TABLE IF EXISTS `wifi_scan`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `wifi_scan` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `serial` varchar(16) DEFAULT NULL,
  `ssid` varchar(64) DEFAULT NULL,
  `bssid` varchar(64) DEFAULT NULL,
  `rssi` int(11) DEFAULT NULL,
  `channel` int(11) DEFAULT NULL,
  `unix_time` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `serial_unix_time_idx` (`serial`,`unix_time`)
) ENGINE=InnoDB AUTO_INCREMENT=3441836 DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2018-01-13 23:45:17
