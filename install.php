<?php

/**
 * Finishes the installation the way the webtrees setup wizard does once data/config.ini.php is
 * written: creates the database tables, adds the default data, then sets up the administrator
 * from WT_USER, WT_NAME, WT_PASS and WT_EMAIL. Every step is safe to repeat.
 *
 * The command line of webtrees cannot do this: only a web request creates the tables.
 */

declare(strict_types=1);

use Fisharebest\Webtrees\Contracts\UserInterface;
use Fisharebest\Webtrees\DB;
use Fisharebest\Webtrees\I18N;
use Fisharebest\Webtrees\Registry;
use Fisharebest\Webtrees\Services\MigrationService;
use Fisharebest\Webtrees\Services\UserService;
use Fisharebest\Webtrees\Webtrees;

require '/var/www/html/vendor/autoload.php';

Webtrees::new()->bootstrap();
I18N::init(code: 'en-US', setup: true);

$config = parse_ini_file(filename: Webtrees::CONFIG_FILE);

DB::connect(
    driver: $config['dbtype'],
    host: $config['dbhost'],
    port: $config['dbport'],
    database: $config['dbname'],
    username: $config['dbuser'],
    password: $config['dbpass'],
    prefix: $config['tblpfx'],
    key: $config['dbkey'],
    certificate: $config['dbcert'],
    ca: $config['dbca'],
    verify_certificate: (bool) $config['dbverify'],
);

$migration_service = Registry::container()->get(MigrationService::class);
$migration_service->updateSchema('\Fisharebest\Webtrees\Schema', 'WT_SCHEMA_VERSION', Webtrees::SCHEMA_VERSION);
$migration_service->seedDatabase();

echo 'Database tables created.', PHP_EOL;

$user_name = (string) getenv('WT_USER');
$real_name = (string) getenv('WT_NAME');
$password  = (string) getenv('WT_PASS');
$email     = (string) getenv('WT_EMAIL');

if ($user_name === '' || $real_name === '' || $password === '' || $email === '') {
    echo 'WT_USER, WT_NAME, WT_PASS and WT_EMAIL are not all set: no administrator created.', PHP_EOL;

    return;
}

$user_service = Registry::container()->get(UserService::class);

// Installing over the tables of a previous installation: the account may already exist.
$admin = $user_service->findByIdentifier($user_name) ?? $user_service->findByIdentifier($email);

if ($admin === null) {
    $admin = $user_service->create($user_name, $real_name, $email, $password);
    $admin->setPreference(UserInterface::PREF_LANGUAGE, (string) getenv('LANG') ?: 'en-US');
    $admin->setPreference(UserInterface::PREF_IS_VISIBLE_ONLINE, '1');

    echo 'Administrator ‘', $user_name, '’ created.', PHP_EOL;
} else {
    $admin->setPassword($password);

    echo 'Administrator ‘', $admin->userName(), '’ already exists: password reset.', PHP_EOL;
}

$admin->setPreference(UserInterface::PREF_IS_ADMINISTRATOR, '1');
$admin->setPreference(UserInterface::PREF_IS_EMAIL_VERIFIED, '1');
$admin->setPreference(UserInterface::PREF_IS_ACCOUNT_APPROVED, '1');
