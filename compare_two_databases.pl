#!/usr/bin/perl -w

#
# sudo perl -MCPAN -e 'install Date::Calc'
#

use strict;
use warnings;
use English;
use DBI;
use Date::Simple;
use List::MoreUtils qw/ any /;
use List::Compare;

# disabling output buffering
$| = 1;

##########################################
# DATABASE connection
##########################################
#$dbConnConditionFilePath = $ARGV[0] || "-";;

our $server01Host = '127.0.0.1';
our $server01Port = '3307';
our $server01User = 'root';
our $server01Pass = 'root';
our $server01Instance = 'db1';

our $server02Host = '127.0.0.1';
our $server02Port = '3307';
our $server02User = 'root';
our $server02Pass = 'root';
our $server02Instance = 'db2';

our $checkDataForMaxRows = 1000;
our $showFullDiffreneces = 1;

our $server01Dbh = DBI->connect("DBI:mysql:dbname=$server01Instance;host=$server01Host;port=$server01Port", $server01User, $server01Pass, {'RaiseError' => 1});
our $server02Dbh = DBI->connect("DBI:mysql:dbname=$server02Instance;host=$server02Host;port=$server02Port", $server02User, $server02Pass, {'RaiseError' => 1});

our %serversData = (
	'server01' => [$server01Instance, $server01Dbh], 
	'server02' => [$server02Instance, $server02Dbh]
);

our @tablesToVerify = ();

@tablesToVerify = dbSchemaVerification();
dbTablesVerification(@tablesToVerify);
dbCheckValues(@tablesToVerify);


$server01Dbh->disconnect();
$server02Dbh->disconnect();
exit;

sub dbCheckValues {
	my @tableList = @_;
	my %tablesWithPrimaryKeyColumns = ();
	
	print "######################################\n";
	print "Data value verification: START\n";
	
	# get primary_key of table from first server
	my @server01ConnData = @{$serversData{'server01'}};
	my $server01Conn = $server01ConnData[1];
	my @server02ConnData = @{$serversData{'server02'}};
	my $server02Conn = $server02ConnData[1];
	
	my $dbName = $server01ConnData[0];
	my $query = "select table_name, COLUMN_NAME from information_schema.columns where TABLE_SCHEMA = '$dbName' and COLUMN_KEY = 'PRI';";
	my $statement = $server01Conn->prepare($query);
	$statement->execute();
	my $statement_ref = $statement->fetchall_arrayref();
	foreach my $row (@$statement_ref) {
		my ($tableName, $columnName) = @$row;
		$tablesWithPrimaryKeyColumns{$tableName} = $columnName;
	}
	
	# estimate how many rows can be in table
	# if more then 500 - check only a news rows
	# if less then 500 - check all rows
	for my $i (0..$#tableList) {
		print "\n#####################################################\n";
		my $tableName = $tableList[$i];
		print "TABLE NAME: $tableName \n";
		my $columnName = $tablesWithPrimaryKeyColumns{$tableName};
		my $query = "";
		if($columnName) {
			$query = "select count(*) from (select * from $tableName order by $columnName desc limit $checkDataForMaxRows) foo;";
		} else {
			$query = "select count(*) from (select * from $tableName limit $checkDataForMaxRows) foo;";
		}
		my $server01Count = runCountQueryOnConn($query, $server01Conn);
		my $server02Count = runCountQueryOnConn($query, $server02Conn);
		
		my @columnsToSelectArray = getArrayBySql("select column_name from information_schema.columns where table_name = '$tableName' AND TABLE_SCHEMA='$dbName'",$server01Conn);
		for my $c (0..$#columnsToSelectArray) {
			$columnsToSelectArray[$c] = "COALESCE(".$columnsToSelectArray[$c].",'')";
		}
		my $columnsToSelect = join(",", @columnsToSelectArray);
		$query = "SELECT concat($columnName,'-',md5(CONCAT($columnsToSelect))) as c FROM $tableName ORDER BY $columnName DESC";
		
		if($server01Count != $server02Count) {
			print "ERROR: Detected a difference in the number of rows in the table: $tableName: Server 01: $server01Count rows, Server 02: $server02Count rows\n";
			$query .= "";
		}elsif( ($server01Count == $server02Count) && ($server01Count > $checkDataForMaxRows) ) {
			print "WARNINGS: In the table $tableName is more then $checkDataForMaxRows rows\n";
			$query .= " LIMIT $checkDataForMaxRows";
		}elsif( ($server01Count == $server02Count) && ($server01Count <= $checkDataForMaxRows) ) {
			$query .= "";
		}
		#print $query."\n";
		my @dataServer01 = getArrayBySql($query, $server01Conn);
		my @dataServer02 = getArrayBySql($query, $server02Conn);
		
		my $lc = List::Compare->new(\@dataServer01, \@dataServer02);
		my @recordIdsWithDiff = ();
		my @server01Only = $lc->get_unique;
		my @server02Only = $lc->get_complement;
		my @LorRonly = $lc->get_symmetric_difference;
		if(scalar(@server01Only) > 0) {
			print "------------------------------------------------------\n";
			print "Element which exists in server01 but not in server02: \n";
			for my $e (@server01Only) {
				my $rowIdValue = substr($e, 0, index($e, '-'));
				if (!(any { $_ eq $rowIdValue} @recordIdsWithDiff)) {
					push(@recordIdsWithDiff, $rowIdValue);
				}
			}
			my $recordIdsWithDiffStr = join(",", @recordIdsWithDiff);
			print "Column name: $columnName, values: $recordIdsWithDiffStr\n";
		}
		@recordIdsWithDiff = ();
		if(scalar(@server02Only) > 0) {
			print "------------------------------------------------------\n";
			print "Element which exists in server02 but not in server01: \n";
			for my $e (@server02Only) {
				my $rowIdValue = substr($e, 0, index($e, '-'));
				if (!(any { $_ eq $rowIdValue} @recordIdsWithDiff)) {
					push(@recordIdsWithDiff, $rowIdValue);
				}
			}
			my $recordIdsWithDiffStr = join(",", @recordIdsWithDiff);
			print "Column name: $columnName, values: $recordIdsWithDiffStr\n";
		}
		@recordIdsWithDiff = ();
		if(scalar(@LorRonly) > 0) {
			print "------------------------------------------------------\n";
			print "Rows which appear at least once in either the first or the second list, but not both: \n";
			for my $e (@LorRonly) {
				my $rowIdValue = substr($e, 0, index($e, '-'));
				if (!(any { $_ eq $rowIdValue} @recordIdsWithDiff)) {
					push(@recordIdsWithDiff, $rowIdValue);
				}
			}
			my $recordIdsWithDiffStr = join(",", @recordIdsWithDiff);
			print "Column name: $columnName, values: $recordIdsWithDiffStr\n";

            my $csvFileNameS01 = "$server01Instance"."_s01_for_$tableName.csv";
            my $csvFileNameS02 = "$server02Instance"."_s02_for_$tableName.csv";
            print "GENERATE CSV file with differences. Files: $csvFileNameS01 and $csvFileNameS02\n";
            $query = "SELECT * FROM $tableName WHERE $columnName IN \($recordIdsWithDiffStr\)";
            #print $query."\n";
            system("echo '$query' |mysql -h$server01Host -p$server01Pass -u$server01User -P$server01Port -D$server01Instance > $csvFileNameS01");
            system("echo '$query' |mysql -h$server02Host -p$server02Pass -u$server02User -P$server02Port -D$server02Instance > $csvFileNameS02");
		}
		
	}
	
	print "Data value verification: DONE\n";
}

sub runCountQueryOnConn {
	my $sql = shift;
	my $connection = shift;
	
	my ($result) = $connection->selectrow_array($sql);
	return $result;
}

sub getArrayBySql {
	my $sql = shift;
	my $connection = shift;
	my @result = ();
	
	#print $sql."\n";
	my $statement = $connection->prepare($sql);
	$statement->execute();
	my $statement_ref = $statement->fetchall_arrayref();
	foreach my $row (@$statement_ref) {
		my ($r) = @$row;
		push(@result, $r);
	}
	return @result;
}

#
# check if columns are the same with the same options
#
sub dbTablesVerification {
	my @tableList = @_;
	
	print "######################################\n";
	print "Columns Schema verification: START\n";
	
	my %columns = (
		'server01' => {}, 
		'server02' => {}
	);
	
	for my $i (0..$#tableList) {
		my $tableName = $tableList[$i];
		while( my ($serverName,@serverData) = each(%serversData)) {
			my $dbName = $serverData[0][0];
			my $dbDbh = $serverData[0][1];
		
			my $query = "SELECT COLUMN_NAME, ORDINAL_POSITION, coalesce(COLUMN_DEFAULT,''), IS_NULLABLE, DATA_TYPE, coalesce(CHARACTER_MAXIMUM_LENGTH, ''), COLUMN_TYPE, COLUMN_KEY, EXTRA ".
			"from information_schema.columns ".
			"where TABLE_SCHEMA = '$dbName' AND TABLE_NAME = '$tableName' ".
			"order by ORDINAL_POSITION ASC;";
		
			my $statement = $dbDbh->prepare($query);
			$statement->execute();
			my $statement_ref = $statement->fetchall_arrayref();
			foreach my $row (@$statement_ref) {
				my ($columnName, $ordinalPosition, $columnDefault, $isNullable, $dataType, $character, $columnType, $columnKey, $extra) = @$row;
                #$columns{$serverName}{$tableName}{$columnName} = ($columnName." | ".$ordinalPosition." | ".$columnDefault." | ".$isNullable." | ".$dataType." | ".$character." | ".$columnType." | ".$columnKey." | ".$extra);
                $columns{$serverName}{$tableName}{$columnName} = sprintf "%-30s|%-5s|%-30s|%-5s|%-10s|%-10s|%-20s|%-10s|%-10s\n", $columnName,$ordinalPosition,$columnDefault,$isNullable,$dataType,$character,$columnType,$columnKey,$extra;
			}
		}
		my $tableVeryficationServer01 = "";
		foreach my $key (keys %{$columns{'server01'}{$tableName}}) {
			$tableVeryficationServer01 .= $columns{'server01'}{$tableName}{$key};
		}
		my $tableVeryficationServer02 = "";
		foreach my $key (keys %{$columns{'server02'}{$tableName}}) {
			$tableVeryficationServer02 .= $columns{'server02'}{$tableName}{$key};
		}
		if($tableVeryficationServer01 ne $tableVeryficationServer02) {
			print "ERROR: The difference from $tableName was detected:\n";
			printf "%-30s|%-5s|%-30s|%-5s|%-10s|%-10s|%-20s|%-10s|%-10s\n", "COLUMN_NAME", "POS","COLUMN_DEFAULT","null?","DATA_TYPE","MAX LENGTH","COLUMN_TYPE","COLUMN_KEY","EXTRA";
			print "Server 01:\n";
			foreach my $key (keys %{$columns{'server01'}{$tableName}}) {
				print $columns{'server01'}{$tableName}{$key};
			}
			print "\nServer 02:\n";
			foreach my $key (keys %{$columns{'server02'}{$tableName}}) {
				print $columns{'server02'}{$tableName}{$key};
			}
			print "\n";
		} else {
			print "CHECK for $tableName: OK! \n";
		}
	}
	
	print "Columns Schema verification: DONE\n";
}


# 
# Get informationa about all tables from information_schema.tables
#
sub dbSchemaVerification {
	print "######################################\n";
	print "Table Schema verification: START\n";
	my %tables = (
		'server01' => {}, 
		'server02' => {}
	);
	my @allUniqueTablesOnServers=();
	my @tableToCheck = ();
	
	
	while( my ($serverName,@serverData) = each(%serversData)) {
		my $dbName = $serverData[0][0];
		my $dbDbh = $serverData[0][1];
		my $query = "SELECT TABLE_NAME, TABLE_TYPE, coalesce(ENGINE,''), coalesce(ROW_FORMAT,''), coalesce(TABLE_COLLATION,'') from information_schema.tables where TABLE_SCHEMA = '$dbName' order by TABLE_NAME ASC;";
		
		my $statement = $dbDbh->prepare($query);
		$statement->execute();
		my $statement_ref = $statement->fetchall_arrayref();
		foreach my $row (@$statement_ref) {
			my ($tableName, $tableType, $engine, $rowFormat, $tableCollation) = @$row;
			$tables{$serverName}{$tableName} = ([$tableName, $tableType, $engine, $rowFormat, $tableCollation]);
			if (!(any { $_ eq $tableName} @allUniqueTablesOnServers)) {
				push(@allUniqueTablesOnServers, $tableName);
			} 
		}
	}
	
	if(length $tables{'server01'} != length $tables{'server02'}) {
		print "There is diffrent between database schemas ! \n";
	}
	
	# check tables with them options
	for my $i (0..$#allUniqueTablesOnServers) {
		my $tableName = $allUniqueTablesOnServers[$i];
		
		# check server01
		my @server01ForTable = @{$tables{'server01'}{$tableName}};
		
		# check server02
		my @server02ForTable = @{$tables{'server02'}{$tableName}};
		
		if(!@server01ForTable) {
			print "ERROR: Table $tableName desn't exist on server01!\n";
		} elsif(!@server01ForTable) {
			print "ERROR: Table $tableName desn't exist on server02!\n";
		} else {
			my $tablePropertisServer01 = join(", ", @server01ForTable);
			#print "$tablePropertisServer01\n";
			my $tablePropertisServer02 = join(", ", @server02ForTable);
			if($tablePropertisServer01 ne $tablePropertisServer02) {
				print "ERROR: Check table schemas on servers, difference was detected:\n";
				print "Compared data: TABLE_NAME, TABLE_TYPE, ENGINE, ROW_FORMAT, TABLE_COLLATION\n";
				print "Server 01: $tablePropertisServer01\n";
				print "Server 02: $tablePropertisServer02\n";
			} else {
				print "Check for $tableName: OK! \n";
			}
			
			# store information about tables to check columns
			push(@tableToCheck, $tableName);
		}
	}
	print "Table Schema verification: DONE\n";
	#print join(",", @tableToCheck)."\n";
	return @tableToCheck;
}

