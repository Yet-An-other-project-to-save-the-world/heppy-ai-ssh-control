#!/usr/bin/env php
<?php
require_once '/home/yap2stw/www/config.php';

try {
    $pdo = new PDO(
        "mysql:host=$dbhost;dbname=$dbname;charset=utf8mb4",
        $dbuser,
        $dbpass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
} catch (PDOException $e) {
    fwrite(STDERR, "DB connection failed: " . $e->getMessage() . "\n");
    exit(1);
}

function usage() {
    echo "Usage:\n";
    echo "  List server names:  ssh-manage.php <discord_name>\n";
    echo "  List server config: ssh-manage.php <discord_name> <server_name> --token <token>\n";
    echo "  Add server:        ssh-manage.php --add --discordname <discord id> --name <server_name> --server <hostname> --port <port> --ssh_key <path> --auth_key <key>\n";
    echo "  Update auth_key:   ssh-manage.php --update authkey --discordname <discord id> --server <server_name> --auth_key <new_key>\n";
    echo "  Generate token:    ssh-manage.php --update token --discordname <discord id>\n";
    echo "  Delete server:     ssh-manage.php --delete <discord_id> <server_name>\n";
    echo "  Test connection:   ssh-manage.php --test <discord_name> <server_name>\n";
    exit(1);
}


function verifySSHConnection($serverName, $discordName) {
    global $dbhost,$dbname,$dbuser,$dbpass;
    try {
        $pdo = new PDO(
            "mysql:host=$dbhost;dbname=$dbname;charset=utf8mb4",
            $dbuser,
            $dbpass,
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
        );

        // Get server config from database
        $stmt = $pdo->prepare("
            SELECT s.name, s.server, s.username, s.port, s.ssh_key, s.auth_key
            FROM ssh_servers s
            JOIN users u ON u.id = s.discord_id
            WHERE u.discord_id = :discord_name AND s.name = :server_name
        ");
        $stmt->execute([
            ':discord_name' => $discordName,
            ':server_name' => $serverName
        ]);
        $server = $stmt->fetch(PDO::FETCH_ASSOC);

        if (!$server) {
            return ['error' => 'Server not found'];
        }

        // Build command with proper escaping
        $cmd = 
            'sudo /opt/heppy_ai/bin/ssh_check.sh ' .
            '--name ' . $server['name'] . ' ' .
            '--host ' . $server['server'] . ' ' .
            '--user ' . $server['username'] . ' ' .
            '--port ' .$server['port'] . ' ' .
            '--auth ' .$server['auth_key'] . ' ' .
            '--key ' . $server['ssh_key'];

        // Execute and get output
        $output = shell_exec($cmd . ' 2>&1');
        if (strpos($output, 'OK') !== false) {
            return ['status' => 'success'];
        } else {
            return ['error' => 'Connection failed', 'details' => $output];
        }

    } catch (PDOException $e) {
        return ['error' => 'Database error', 'details' => $e->getMessage()];
    }
}


function generateRandomToken($length = 64) {
    $characters = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    $token = '';
    for ($i = 0; $i < $length; $i++) {
        $token .= $characters[rand(0, strlen($characters) - 1)];
    }
    return $token;
}


if ($argc < 2) usage();

// Parse args into named + positional
$args = [];
for ($i = 1; $i < $argc; $i++) {
    if (substr($argv[$i], 0, 2) === "--") {
        $key = ltrim($argv[$i], "-");
        $val = $argv[$i+1] ?? true;
        if ($val !== true && substr($val, 0, 2) !== "--") {
            $args[$key] = $val;
            $i++;
        } else {
            $args[$key] = true;
        }
    } else {
        $args[] = $argv[$i];
    }
}

if (isset($args['test'])) {
    if (count($args) < 2) {
        fwrite(STDERR, "Missing required arguments for test mode\n");
        usage();
    }
    $discord_name = $args['discord_id'];
    $server_name = $args['server'];
    
    $result = verifySSHConnection($server_name, $discord_name);
    echo json_encode($result, JSON_PRETTY_PRINT) . PHP_EOL;
    exit(@$result['error'] ? 1 : 0);
}




// UPDATE TOKEN MODE
if (isset($args['update']) && $args['update'] === "token") {
    if ( empty($args['discordname'])) {
        fwrite(STDERR, "Missing required options for token update.\n");
        usage();
    }

    $newToken = generateRandomToken();

    $sql = "UPDATE ssh_servers SET token = :token 
            WHERE discord_id = (SELECT id FROM users WHERE name = :discord_name)";
    
    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':token' => $newToken,
        ':discord_name' => $args['discordname']
    ]);

    echo json_encode(['token' => $newToken], JSON_PRETTY_PRINT) . PHP_EOL;
    exit;
}

// UPDATE TOKEN MODE
if (isset($args['update']) && $args['update'] === "authkey") {
    if ( empty($args['discordname'])) {
        fwrite(STDERR, "Missing required option discordname <discord id> for auth update.\n");
    }
    if ( empty($args['server'])) {
        fwrite(STDERR, "Missing required options the ssh server for auth update.\n");
    }
    if ( empty($args['auth'])) {
        fwrite(STDERR, "Missing required options for auth token for auth update.\n");
    }

    if (empty($args['auth']) || empty($args['server']) || empty($args['discordname'])) { 
        usage();
        exit(1);
    }
    $auth = $args['auth'];
    $sql = "UPDATE ssh_servers SET auth_key = :auth 
            WHERE discord_id = (SELECT id FROM users WHERE name = :discord_name) AND name = :server ";
    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':auth' => $auth,
        ':discord_name' => $args['discordname'],
        ':server' => $args['server']
    ]);

    echo "auth set";
    exit;
}

// LIST SERVER NAMES (no token required)
if (count($args) === 1) {
    $discord_name = $args[0];
    $sql = "SELECT s.name FROM ssh_servers s
            JOIN users u ON u.id = s.discord_id
            WHERE u.discord_id = :discord_name";
    $stmt = $pdo->prepare($sql);
    $stmt->execute([':discord_name' => $discord_name]);
    $servers = $stmt->fetchAll(PDO::FETCH_COLUMN);
    if ($servers) {
       echo json_encode($servers, JSON_PRETTY_PRINT) . PHP_EOL;
       exit(0);
    } else {
       echo json_encode(["error" => "No servers found go to https://www.yetanotherprojecttosavetheworld.org/ssh_management.php to add servers"], JSON_PRETTY_PRINT) . PHP_EOL;
       exit(1);
    }
}

// LIST SERVER CONFIG (requires token)
if (count($args) >= 2) {
    $discord_name = $args[0];
    $server_name = $args[1];
    $token = $args['token'];

    // Get full server config
    $sql = "SELECT s.name, s.username, s.server, s.port, s.ssh_key, s.auth_key
            FROM ssh_servers s
            JOIN users u ON u.id = s.discord_id
            WHERE u.discord_id = :discord_name AND s.name = :server_name AND s.token = :token";
    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':discord_name' => $discord_name,
        ':server_name' => $server_name,
        ':token' => $token
    ]);
    $result = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($result) {
       echo json_encode($result, JSON_PRETTY_PRINT) . PHP_EOL;
       exit(0);
    } else {
      //Error checking for the bot to know what is going on
      // Get full server config
      $sql = "SELECT s.name, s.username, s.server, s.port, s.ssh_key, s.auth_key
              FROM ssh_servers s
              JOIN users u ON u.id = s.discord_id
              WHERE u.discord_id = :discord_name AND s.name = :server_name";
      $stmt = $pdo->prepare($sql);
      $stmt->execute([
          ':discord_name' => $discord_name,
          ':server_name' => $server_name
      ]);
      $result = $stmt->fetch(PDO::FETCH_ASSOC);
      if ($result) {
         echo json_encode(["error" => "TOKEN INVALID please try again"], JSON_PRETTY_PRINT) . PHP_EOL;
      } else {
         echo json_encode(["error" => "ssh Server not found"], JSON_PRETTY_PRINT) . PHP_EOL;
         exit(1);
      }
    }
}

usage();
