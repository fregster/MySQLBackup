MySQLBackup
===========

Slightly More Advanced MySQL backup (MAB) Bash script with Diff support

This is a bash based script which can backup MySQL databases with transaction safe support.
It supports the ability to create a full backup and then diff based patch files from the master backup.
Diff backups can significantly reducing the on disk file size of many systems.

There is still work to do to complete the feature set but most users should be able to use this now.

This is designed to be ran as a pre-backup process or cron job in conjunction with a proper backup process IE Bareos.
