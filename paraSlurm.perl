#!/sw/bin/perl

# The MIT License (MIT)
# Copyright (c) Michael Hiller, 2016

# Version 1.0

# implements parasol functionality for Slurm
# it uses files in a local directory .para/ to keep track of the jobs in a jobList and their status

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use Scalar::Util::Numeric qw(isint);
use Date::Manip;
use List::MoreUtils qw( natatime );

######################################
# PARAMETERS YOU MUST CONFIGURE
my $clusterHeadNode = "falcon1";		# specify here the hostname of the cluster head node (the computer that is able to submit jobs to LSF). The script will only run when executed on this node. 
my $queue = "short";						# short queue is the default
my $maxRunTimeQueue = "long";			# the queue with the maximum runtime
# used if jobs reach the run time limit of a queue and have to be resubmitted (used in pushCrashed)
my %Queue2Order;
$Queue2Order{"short"}  = 0;
$Queue2Order{"shortmed"}  = 1;
$Queue2Order{"medium"} = 2;
$Queue2Order{"day"}    = 3;
$Queue2Order{"long"}   = 4;
my %Order2Queue;
$Order2Queue{0} = "short";
$Order2Queue{1} = "shortmed";
$Order2Queue{2} = "medium";
$Order2Queue{3} = "day";
$Order2Queue{4} = "long";
######################################

my $maxNumJobsWarning = 10000;
my $maxNumJobsStop = 12500;

######################################
# optional configurable default parameters
my $maxNumResubmission = 3;			# max number of times a job gets resubmitted, in case it crashed
my $numAtATime = 300;					# call sacct with that many jobIDs max
my $maxNumOutFilesPerDir = 1000;		# we generate LSF output files for each job in the .para/$jobListName/$subDir dir. 
												# This value determines how many files will be generated per $subDir to avoid overloading lustre with too many files in a single dir. 
my $maxNumFastSleepCycles = 10;		# do that many cycles where we sleep only $sleepTime1, after that sleep $sleepTime2
my $sleepTime1 = 60;						# time in seconds
my $sleepTime2 = 120;
#my $sleepTimeLSFBusy = 180;			# time to wait if LSF is too busy
#my $sleepTimesacctError = 50;			# time to wait if LSF sacct returns corrupted output
#####################################

#####################################
# other parameters
$| = 1;										# == fflush(stdout)
my $verbose = 0;							# flag
my $noResubmitIfQueueMaxTimeExceeded = 0;           # if set to 1, do not resubmit the jobs that failed because they exceeded the runtime limit of the queue
my $resubmitToSameQueueIfQueueMaxTimeExceeded = 0;  # if set to 1, resubmit the jobs that failed because they exceeded the runtime limit of the queue, but resubmit to the same (rather than the next longest) queue. 
                                                    # Only useful, if your job checks which preliminary results exist (e.g. for input elements the output file already exist)
my $keepBackupFiles = 0;            # if set, keep a backup of every internal para file in a dir .para/backup/
my $totalNoJobsPushed = -1;			# in case of push or make, keep track of how many jobs were pushed
my $sbatchParameters = "";				# default parameters for bsub
my $numCores = 1;							# number of cores requested per job
my $memoryMb = -1;						# memory in MB requested per job
#####################################

# usage
my $usage = "$0 action jobListName [jobListFile] [-q queue] [-memoryMb numInMb] [-numCores num] [-p sbatchParameters] [-v|verbose] [-maxNumResubmission int] [-noResubmitIfQueueMaxTimeExceeded] [-resubmitToSameQueueIfQueueMaxTimeExceeded] [-keepBackupFiles]
where action can be:    make, push, pushCrashed, check, wait, stop, chill, time, crashed, clean\n
\tmake          pushes the joblist, monitors progress, pushes failed jobs again a maximum of $maxNumResubmission times, waits until all jobs are done or jobs crashed >$maxNumResubmission times
\tpush          pushes the joblist
\tpushCrashed   determines which jobs crashed and pushes those jobs again unless they failed $maxNumResubmission times already. It uses the same bsub parameters. Queue is the same, unless a job failed with exceeding the runtime limit.
\tcheck         checks how many jobs in the current joblist are done. Exit code 0 if all succeeded. Otherwise exit code 255. 
\twait          'connects' to a running jobList and waits until the running and pending jobs are done, pushes failed jobs again a max of $maxNumResubmission times.
\tstop          stops all running and pending jobs in the jobList --> You can recover all stopped and crashed jobs with 'crashed'
\tchill         stops all pending jobs only. Lets the running jobs continue to run. --> You can recover all stopped and crashed jobs with 'crashed'
\ttime          outputs runtime statistics and an estimation when all jobs are finished
\tcrashed       outputs all crashed jobs into the given output filename
\tclean         remove all internal para files and LSF output files for the given jobListName
The number of input parameters depends on the action:
\t$0 make          jobListName  jobListFile  [-q|queue short|shortmed|medium|day|long] [-memoryMb numInMb] [-numCores num] [-p|parameters \"additional parameters for bsub\"] [-maxNumResubmission int] [-noResubmitIfQueueMaxTimeExceeded] [-resubmitToSameQueueIfQueueMaxTimeExceeded]
\t$0 push          jobListName  jobListFile  [-q|queue short|shortmed|medium|day|long] [-memoryMb numInMb] [-numCores num] [-p|parameters \"additional parameters for bsub\"] [-maxNumResubmission int] [-noResubmitIfQueueMaxTimeExceeded] [-resubmitToSameQueueIfQueueMaxTimeExceeded]
\t$0 pushCrashed   jobListName  
\t$0 check         jobListName
\t$0 wait          jobListName
\t$0 stop          jobListName
\t$0 chill         jobListName
\t$0 time          jobListName
\t$0 crashed       jobListName  outputJobListFile
\t$0 clean         jobListName\n
General parameters
\t-v|--verbose                                 enable verbose output
\t-maxNumResubmission int                      set the max number of times a crashed job will be pushed again (default $maxNumResubmission). NOTE: has only an effect when doing para make
\t-noResubmitIfQueueMaxTimeExceeded            do not resubmit the jobs that failed because they exceeded the runtime limit of the queue (default is do resubmit)
\t-resubmitToSameQueueIfQueueMaxTimeExceeded   resubmit the jobs that failed because they exceeded the runtime limit of the queue, but resubmit to the same (rather than the next longest) queue. 
\t                                             Only useful, if your job checks which preliminary results exist (e.g. for input elements the output file already exist).
\t-keepBackupFiles                             if set, keep a backup of every internal para file in a dir .para/backup/ (backup files will be produced everytime the internal files are updated)
";

# first thing: check if the script is executed on $clusterHeadNode
my $hostname = $ENV{'HOSTNAME'};
die "######### ERROR #########: You have to execute $0 on $clusterHeadNode! Not on $hostname.\n" if ($hostname ne $clusterHeadNode);

# since the default is only 5 GB and because 250 GB for 24 cores is >10GB, we request 10 GB by default
$memoryMb = 10000;

# parse options
GetOptions ("v|verbose"  => \$verbose, "p|parameters=s" => \$sbatchParameters, "q|queue=s" => \$queue, "maxNumResubmission=i" => \$maxNumResubmission, 
            "noResubmitIfQueueMaxTimeExceeded" => \$noResubmitIfQueueMaxTimeExceeded, "resubmitToSameQueueIfQueueMaxTimeExceeded" => \$resubmitToSameQueueIfQueueMaxTimeExceeded, 
            "keepBackupFiles" => \$keepBackupFiles, "numCores=i" => \$numCores, "memoryMb=i" => \$memoryMb) 
		|| die "$usage\n";
die "ERROR: Set only one of -resubmitToSameQueueIfQueueMaxTimeExceeded and -noResubmitIfQueueMaxTimeExceeded but not both !" if ($resubmitToSameQueueIfQueueMaxTimeExceeded == 1 && $noResubmitIfQueueMaxTimeExceeded == 1);
die "Parameters missing!!\n\n$usage\n" if ($#ARGV < 1);

# global parameters. Needed for every command. 
my $jobListName = $ARGV[1];
# internal .para file names keeping track of the jobs and their status
my $paraJobsFile = "./.para/.para.jobs.$jobListName";
my $paraStatusFile = "./.para/.para.status.$jobListName";
my $paraSbatchParaFile = "./.para/.para.sbatchParameters.$jobListName";
my $paraJobNoFile = "./.para/.para.jobNo.$jobListName";
my $paraJobsFilebackup = "./.para/backup/.para.jobs.$jobListName.backup";
my $paraStatusFilebackup = "./.para/backup/.para.status.$jobListName.backup";
my $paraSbatchParaFilebackup = "./.para/backup/.para.sbatchParameters.$jobListName.backup";

# test if the given action is correct
my $action = $ARGV[0];
die "$usage\n" if (! ($action eq "make" || $action eq "wait" || $action eq "push" || $action eq "pushCrashed" || $action eq "check" || $action eq "time" || $action eq "stop" || $action eq "chill" || $action eq "crashed" || $action eq "clean") );
# if push or make: test if the queue is correct and if jobList exist
if ($action eq "make" || $action eq "push") {
	die "######### ERROR #########: parameter -q|queue must be set to short, shortmed, medium, day, long. Not to $queue.\n" if (! ($queue eq "short" || $queue eq "shortmed" || $queue eq "medium" || $queue eq "day" || $queue eq "long"));
	# test if jobListname and jobList file are given
	die "Parameters missing!!\n\n$usage\n" if ($#ARGV < 2);
	# test if jobList exist
	die "######### ERROR #########: jobListFile $ARGV[2] does not exist\n" if (! -e $ARGV[2]);
# otherwise check if the internal .para files exist and check if these files have an entry for every submitted job
}else{
	# test if the internal job and jobStatus files exist in the current directory
	checkIfInternalFilesExist($jobListName);
}

# based on the action, decide what to do and test if the number of parameters is correct
if ($action eq "make") {
	# now push and then wait until finished
	pushJobs();
	# need to sleep 10 sec before checking jobIDs as otherwise the sacct output is empty
	sleep(10);
	check();
	waitForJobs();
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	printf "RUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d (%d of them failed $maxNumResubmission times)\n", $numRun,$numPend,$numDone,$numFailed,$numFailed-$allnumFailedLessThanMaxNumResubmission;
	if ($allDone == 1) {
		print "*** ALL JOBS SUCCEEDED ***\n";
		exit 0;
	}else {
		print "*** CRASHED: Some jobs failed $maxNumResubmission times !!  Run '$0 crashed' to list those crashed jobs. ***\n";
		exit(-1);
	}	

} elsif ($action eq "push") {
	# now push 
	pushJobs();
	# need to sleep 10 sec before checking jobIDs as otherwise the sacct output is empty. This prevents the user from running para check, which would mess up the .para/ files
	sleep(10);

} elsif ($action eq "pushCrashed") {
	# For pushing failed jobs again, we need the bsub parameter file.
	die "######### ERROR #########: internal file $paraSbatchParaFile not found in this directory\n" if (! -e "$paraSbatchParaFile");

	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	printf "numJobs: %-7d\tRUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d  (%d of them failed $maxNumResubmission times)\tallDone: %s\n", $numJobs,$numRun,$numPend,$numDone,$numFailed,$numFailed-$allnumFailedLessThanMaxNumResubmission,($allDone == 1 ? "YES" : "NO");	
	# push crashed jobs again, if some failed less than $maxNumResubmission times
	if ($allnumFailedLessThanMaxNumResubmission > 0) {
		pushCrashed($jobIDsFailedLessThanMaxNumResubmission);
	}else{
		if ($numFailed > 0 && $allnumFailedLessThanMaxNumResubmission == 0)	{
			print "All $numFailed crashed jobs crashed $maxNumResubmission times already --> No job is repushed !!  Run '$0 crashed' to list those crashed jobs, fix them and submit a new jobList.\n";
		}elsif ($numFailed == 0) {
			print "There are NO crashed jobs. \n";
		}
	}

} elsif ($action eq "wait") {
	# wait involved potentially pushing failed jobs again. Therefore we need the bsub parameter file.
	die "######### ERROR #########: internal file $paraSbatchParaFile not found in this directory\n" if (! -e "$paraSbatchParaFile");
	waitForJobs();

	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	printf "RUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d (%d of them failed $maxNumResubmission times)\n", $numRun,$numPend,$numDone,$numFailed,$numFailed-$allnumFailedLessThanMaxNumResubmission;
	if ($allDone == 1) {
		print "*** ALL JOBS SUCCEEDED ***\n";
		exit 0;
	}else {
		print "*** CRASHED: Some jobs failed $maxNumResubmission times !!  Run '$0 crashed' to list those crashed jobs. ***\n";
		exit(-1);
	}	

} elsif ($action eq "check") {
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	printf "RUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d (%d of them failed $maxNumResubmission times)\n", $numRun,$numPend,$numDone,$numFailed,$numFailed-$allnumFailedLessThanMaxNumResubmission;
	if ($allDone == 1) {
		print "*** ALL JOBS SUCCEEDED ***\n";
		exit 0;
	}elsif ($allDone == -1) {
		print "*** CRASHED: Some jobs failed $maxNumResubmission times !!  Run '$0 crashed' to list those crashed jobs. ***\n";
	}	
	if ($allnumFailedLessThanMaxNumResubmission > 0) {
		print "*** Some jobs crashed. Run '$0 pushCrashed' to push the crashed jobs again. Run '$0 crashed' to list those crashed jobs. ***\n";
	}
	
	# para check can be used to test if the entire jobList succeeded (exit 0). Otherwise if jobs are still running or failed, exit -1.
	exit -1;

} elsif ($action eq "time") {
	gettime();

} elsif ($action eq "stop") {
	killJobs("stop");

} elsif ($action eq "chill") {
	killJobs("chill");

} elsif ($action eq "crashed") {
	# test if output filename is given as the third parameter
	die "Parameters missing!!\n\n$usage\n" if ($#ARGV < 2);	
	crashed();

} elsif ($action eq "clean") {
	clean();

=pod
} elsif ($action eq "restore") {
	restore();
=cut
}


#####################################################
# die if the $paraJobsFile and $paraStatusFile file for the given jobListName don't exist
#####################################################
sub checkIfInternalFilesExist {
	die "######### ERROR #########: internal file $paraJobsFile not found in this directory\n" if (! -e "$paraJobsFile");
	die "######### ERROR #########: internal file $paraStatusFile not found in this directory\n" if (! -e "$paraStatusFile");
	
	# compare if the line count in $paraJobsFile and $paraStatusFile equals $noOfSubmittedJobs --> otherwise these files are corrupted
	my $lineNoparaJobsFile = `cat $paraJobsFile | wc -l`; chomp($lineNoparaJobsFile);
	my $lineNoparaStatusFile = `cat $paraStatusFile | wc -l`; chomp($lineNoparaStatusFile);
	my $noOfSubmittedJobs = `cat $paraJobNoFile`; chomp($noOfSubmittedJobs);
	
	print "checkIfInternalFilesExist(): number of lines in $paraJobsFile = $lineNoparaJobsFile. $paraStatusFile = $lineNoparaStatusFile. Number of submitted jobs $noOfSubmittedJobs\n" if ($verbose);
	
	if ($noOfSubmittedJobs != $lineNoparaJobsFile) {
		die "ERROR: the number of lines in $paraJobsFile ($lineNoparaJobsFile) does not equal the number of submitted jobs $noOfSubmittedJobs --> internal para files are corrupted\n";
	}
	if ($noOfSubmittedJobs != $lineNoparaStatusFile) {
		die "ERROR: the number of lines in $paraStatusFile ($lineNoparaStatusFile) does not equal the number of submitted jobs $noOfSubmittedJobs --> internal para files are corrupted\n";
	}
}

#####################################################
# push a single job and return jobID 
#####################################################
sub pushSingleJob {
	my ($jobPrefix, $outFile, $job) = @_;

	# add the -e and -o  stderr/stdout redirect to the given outfile to the jobFile
	# both stderr and stdout go to the same file
	$jobPrefix .= "#SBATCH -o $outFile\n";
	$jobPrefix .= "#SBATCH -e $outFile\n";

	# check if the job has special characters and mask single quotes since we use bash printf to submit the job
	if ($job =~ /[!$^&*(){}"'?]/) {
		print "\t\t job with special chars: $job\n" if ($verbose);
		# NOTE: We have to mask every backslash in addition here. This replace does ' --> '\\\''
		#	'-bash-4.2$ printf 'XX '\\\'' XX\n'
		#	XX ' XX
		$job =~ s/'/'\\\''/g;
		print "\t\t\tgets masked: $job\n" if ($verbose);
	}

	# add the job
	my $sbatchCall = $jobPrefix . $job;
	print "SUBMIT this implicit jobFile to sbatch: $sbatchCall\n\n" if ($verbose);

	# we use bash printf to submit the above string as a file to sbatch
	my $command = "sbatch <<< \"\$( printf '$sbatchCall' )\"";
	print "\t$command\n" if ($verbose);
	my $result = `$command`;
	die "######### ERROR ######### in pushSingleJob: $command failed with exit code $?\n" if ($? != 0);
	print "$result\n" if ($verbose);

	# get the job ID
	my $ID = -1;
	if ($result =~ /^Submitted batch job (\d+)$/) {
		$ID = $1;
	}else{
		die "ERROR: cannot parse the result from sbatch: $result\n\nSubmitted command was $command\n\n";
	}
	die "######### ERROR #########: $command results in an ID that is not a number: $ID\n" if (! isint($ID));
	return $ID;
}


#####################################################
# get the lockfile (atomic operation)
#####################################################
sub getLock {
	print "Waiting to get ./lockFile.$jobListName   ..... [Takes too long? Did a previous para run died? If so, open a new terminal and   rm -f ./lockFile.$jobListName ] .....  ";
	system "lockfile -1 ./lockFile.$jobListName" || die "######### ERROR #########: cannot get lock file: ./lockFile.$jobListName\n";
	print "got it\n";
}

#####################################################
# push the entire joblist, create the internal .para files to keep track of all pushed jobs
#####################################################
sub pushJobs {

	my $jobListFile = $ARGV[2];
   
	# check if the max number of jobs is not exceeded
	my $jobNumCheck = `cat $jobListFile | wc -l`; chomp($jobNumCheck);
	die "ERROR: You have $jobNumCheck jobs in $jobListFile, which is too much for the cluster. Reduce the number of jobs to <$maxNumJobsWarning and push again." if ($jobNumCheck > $maxNumJobsStop);
	print STDERR "!!! WARNING !!!  With $jobNumCheck jobs in $jobListFile you have more than $maxNumJobsWarning jobs. !!\n" if ($jobNumCheck > $maxNumJobsWarning);

	
	# create the .para dir, in case it does not exist
	if (! -d "./.para") {
		system("mkdir ./.para") == 0 || die "######### ERROR #########: cannot create the ./.para directory\n";	
	}
	if (($keepBackupFiles == 1) && (! -d "./.para/backup")) {
		system("mkdir ./.para/backup") == 0 || die "######### ERROR #########: cannot create the ./.para/backup directory\n";	
	}

	# make sure we never clobber the $paraJobsFile and $paraStatusFile files if they already (or still) exist. 
	# We avoid clobbering the files if a user accidentally pushes the jobList or another list using the same jobListName
   if (-e  "$paraJobsFile" || -e "$paraStatusFile" || -e "$paraSbatchParaFile" || -e "$paraJobNoFile" || -d "./.para/$jobListName") {
		die "######### ERROR #########: Looks like a jobList with the name $jobListName already exists (files ./.para/.para.[jobs|status|sbatchParameters|jobNo].$jobListName and/or .para/$jobListName exist).
If this is not an accident, do \n\tpara clean $jobListName\nand call again\n" 
	}

	print "**** PUSH Jobs to queue: $queue\n";

	### we submit the jobs via a jobfile to sbatch
	# get the jobfile part that is fixed
	my $jobFileFixedPart = "#!/bin/bash\n";

	# add joblist name
	$jobFileFixedPart .= "#SBATCH -J $jobListName\n";

	# add number of nodes (always 1)
	$jobFileFixedPart .= "#SBATCH --nodes=1\n";

	# add number of cores
	if ($numCores > 1) {
		$jobFileFixedPart .= "#SBATCH --cpus-per-task=$numCores\n";
	}else{
		$jobFileFixedPart .= "#SBATCH --cpus-per-task=1\n";
	}
	print "**** Number of cores requested: $numCores\n";

	# add memory if this is specified
	if ($memoryMb != -1) {
		$jobFileFixedPart .= "#SBATCH --mem-per-cpu=$memoryMb\n";
		print "**** MB of memory requested: $memoryMb\n";
	}
	print "SUBMIT this implicit jobFile to sbatch: $jobFileFixedPart\n\n" if ($verbose);

	# write the job parameters to $paraSbatchParaFile    We need these parameters in case jobs fail and have to be pushed again.
	# Note that the queue/runtime depends on the job as jobs that exceed the max runtime of the specified queue will be pushed to a longer queue.
	# The queue/runtime is therefore not added here.
	getLock();
	open (filePara, ">$paraSbatchParaFile") || die "######### ERROR #########: cannot create $paraSbatchParaFile\n";
	print filePara "$jobFileFixedPart\n";
	close filePara;
    
    # add runtime, depending on the queue
    if ($queue eq "short") {
        $jobFileFixedPart .= "#SBATCH --time=01:00:00\n";
    }elsif ($queue eq "shortmed") {
        $jobFileFixedPart .= "#SBATCH --time=03:00:00\n";
    }elsif ($queue eq "medium") {
        $jobFileFixedPart .= "#SBATCH --time=08:00:00\n";
    }elsif ($queue eq "day") {
        $jobFileFixedPart .= "#SBATCH --time=24:00:00\n";
    }elsif ($queue eq "long") {
        # 2 weeks
        $jobFileFixedPart .= "#SBATCH --time=336:00:00\n";
        $jobFileFixedPart .= "#SBATCH --partition=long\n";
    }else {
        die "ERROR: queue is neither short/shortmed/medium/day/long.\n";
    }

	# create the two internal para files listing the jobs and their status
	open (fileJobs, ">$paraJobsFile") || die "######### ERROR #########: cannot create $paraJobsFile\n";
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot create $paraStatusFile\n";
	print "pushJobs: push the following jobs .... \n" if ($verbose);
	
	# read all the jobs and push
	open(file1, $jobListFile) || die "######### ERROR #########: cannot open $jobListFile\n";
	my $line;
	my $numJobs = 0;
	my $subDir = 0;
	system("mkdir -p ./.para/$jobListName/")  == 0 || die "######### ERROR #########: cannot create the ./.para/$jobListName directory\n";	
	while ($line = <file1>) {
		chomp($line);

		# start a new subdir if $maxNumOutFilesPerDir files in the current $subdir are reached
		if ($numJobs % $maxNumOutFilesPerDir == 0) {
			$subDir ++;
			system("mkdir -p ./.para/$jobListName/$subDir")  == 0 || die "######### ERROR #########: cannot create the ./.para/$jobListName/$subDir directory\n";	
		}

		# push the job and get the jobID back
		# the jobName is $jobListName/$subDir/o.$numJobs which is the output file in the .para dir
		my $jobName = "$jobListName/$subDir/o.$numJobs";
		my $ID = pushSingleJob($jobFileFixedPart, "./.para/$jobName", $line);

		# write job, its (current) queue and its ID and name to $paraJobsFile
		print fileJobs "$ID\t$jobName\t$queue\t$line\n";
		# write the jobID, jobName and PEND to $paraStatusFile
		print fileStatus "$ID\t$jobName\tPENDING\t0\t-1\n";

		$numJobs ++;
	}
	close file1;
	close fileJobs;
	close fileStatus;
	
	# make a backup copy with version number 0 that refers to these original files
	firstBackup();

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	
	print "DONE.\n$numJobs jobs pushed using parameters: -q $queue $sbatchParameters\n\n";
	
	# keep track of how many jobs we have pushed --> write to a file
	open (fileJobNo, ">$paraJobNoFile") || die "######### ERROR #########: cannot create $paraJobNoFile\n";
	print fileJobNo "$numJobs\n";
	close fileJobNo;
	
	# in case of para make, store job number in a global variable
	$totalNoJobsPushed = $numJobs;
}


#####################################################
# check the status of all jobs
# Only run sacct for jobs that are not DONE. When a job finishes (FAILED/RUNNING/PENDING --> COMPLETED), run getRunTime to get store the runtime for that job.
#####################################################
sub check {

	getLock();

	# for overall stats
	my $allnumRun = 0;
	my $allnumPend = 0;
	my $allnumFailed = 0;
	my $allnumDone = 0;
	
	# get all IDs for jobs that are not DONE from $paraStatusFile file
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my @oldStatus = <fileStatus>;
	chomp(@oldStatus);
	close fileStatus;
	# sort by ID
	my @oldStatusSort = sort( {
		my $ID1 = (split(/\t/, $a))[0];
		my $ID2 = (split(/\t/, $b))[0];
		return $ID1 <=> $ID2;
	}  @oldStatus); 
	@oldStatus = @oldStatusSort;
	if ($verbose) {
		$" = "\n\t"; print "CHECK: old Status array:\n\t@oldStatus\n";
	}
	my @IDs;	
	my $newStatus_ = "";	 # status of all jobs: Those that are COMPLETED and the update for FAILED/PENDING/RUNNING jobs as returned from runsacct()
	for (my $i=0; $i<=$#oldStatus; $i++) {
		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];
		if ($status ne "COMPLETED") {
			# check this job with sacct later --> add to IDs
			push @IDs, $jobID;
		}else{
			# jobs was marked as DONE from the last call of check() --> just increase the counter and add to $newStatus_ as the status of this job will not change anymore (also its runtime, which we have determined already)
			$allnumDone ++;
			$newStatus_ .= "$oldStatus[$i]\n";
		}
	}
	print "\n\nCHECK: IDs @IDs\n" if ($verbose);

	# lets run sacct --format=JobID,State,cputimeraw,exitcode -j 65390,65377,65380 -n
	# we can easily give 1000 job IDs at once, use the natatime function for that (List::MoreUtils)
	$" = ",";	   # comma as separator for the array
	my $it = natatime $numAtATime, @IDs;
	while (my @vals = $it->())  {
		# run sacct, we don't make use of numRun etc here
		my ($status, $numRun, $numPend, $numFailed, $numDone) = runsacct("@vals");
		$allnumRun += $numRun;
		$allnumPend += $numPend;
		$allnumFailed += $numFailed;
		$allnumDone += $numDone;	
		$newStatus_ .= $status;
	}

	# sort by ID
	my @newStatus = sort( {
		my $ID1 = (split(/\t/, $a))[0];
		my $ID2 = (split(/\t/, $b))[0];
		return $ID1 <=> $ID2;
	}  split(/\n/, $newStatus_)  );	 # split the string $newStatus_ to get an array to sort
	if ($verbose) {
		$" = "\n\t"; print "CHECK: new Status array:\n\t@newStatus\n";
	}
	
	# count how many jobs could be repushed and collect their jobIDs (is used for pushCrashed())
	my $allnumFailedLessThanMaxNumResubmission = 0;		
	my @jobIDsFailedLessThanMaxNumResubmission;
	
	# now clobber the $paraStatusFile file and update the status of each job
	# @newStatus is the new status of each job after running sacct. @oldStatus is the content of $paraStatusFile
	backup();
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot create $paraStatusFile\n";
	for (my $i=0; $i<=$#newStatus; $i++) {

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID1, $jobName1, $status1, $howOftenFailed1, $runTime1) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];
		my ($jobID2, $jobName2, $status2, $howOftenFailed2, $runTime2) = (split(/\t/, $newStatus[$i]))[0,1,2,3,4];
#		print "\tCHECK: compare\n\t$oldStatus[$i]\n\t$newStatus[$i]\n" if ($verbose);
		
		# Important: We will compare old and new status. Works only if the two arrays are sorted. Check ! 
		print STDERR "######### ERROR ######### in check: jobID1 != jobID2  ($jobID1 != $jobID2)\n" if ($jobID1 != $jobID2);

		# now update
		# a job failed
		if (($status1 eq "PENDING" || $status1 eq "RUNNING") && ($status2 eq "FAILED") ) {
			print "\tCHECK: $jobID1 crashed ($status1 --> $status2)   num times crashed before $howOftenFailed1\n" if ($verbose);
			$howOftenFailed1 ++;
			if ($howOftenFailed1 < $maxNumResubmission) {
				# push the job if noResubmitIfQueueMaxTimeExceeded is not set OR if the job did not exceed the runtime limit
				if ($noResubmitIfQueueMaxTimeExceeded == 0 || doesCrashedJobReachedRuntimeLimit($jobID1) == 0) {
					push @jobIDsFailedLessThanMaxNumResubmission, $jobID1;
					$allnumFailedLessThanMaxNumResubmission ++;	
				}else{
					print "\t--> Do not push this job again because it crashed by exceeding the queue runtime and noResubmitIfQueueMaxTimeExceeded is set! (set #crashes to $maxNumResubmission)\n" if ($verbose);
					$howOftenFailed1 = $maxNumResubmission;	
				}
			}
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";   # time does not matter here

		# a job went from pend to run
		}elsif ( ($status1 eq "PENDING") && ($status2 eq "RUNNING") ) {
			print "\tCHECK: $jobID1 is now running ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";
			
		# a job is still running
		}elsif ( ($status1 eq "RUNNING") && ($status2 eq "RUNNING") ) {
			print "\tCHECK: $jobID1 is still running ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";

		# a job is still pending
		}elsif ( ($status1 eq "PENDING") && ($status2 eq "PENDING") ) {
			print "\tCHECK: $jobID1 is still pending ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status1\t$howOftenFailed1\t-1\n";
			
		# a job is now done (was RUN or PEND before). In case of EXIT the job must have been repushed and pushCrashed would have updated the status to PEND
		}elsif ( ($status1 ne "COMPLETED") && ($status2 eq "COMPLETED") ) {
			print "\tCHECK: $jobID1 succeeded since checking last time ($status1 --> $status2)\n" if ($verbose);
			# if the status of the job was determined not by sacct but by looking into its output file, we have the runtime already. 
			# otherwise, we try to get the runtime here. As the job likely finished not so long time ago, sacct -l should still find the job (faster solution). 
			#   If sacct does not find the job, the getRunTime fct calls bhist instead.
			my $runTime = -1;
			if ($runTime2 > 0) {			# NOTE: if a job took only 0 seconds, getRunTime returns 1 second
				$runTime = $runTime2;
			}else{
				$runTime = getRunTime($jobID1, -1);		# NOTE: This job finished, therefore we don't need to pass the current time. 
			}
			# write the proper runTime to the file. Then we never have to get the runtime for that job again. 
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t$runTime\n";

		# a job is was done before
		}elsif ( ($status1 eq "COMPLETED") && ($status2 eq "COMPLETED") ) {
			print "\tCHECK: $jobID1 succeeded before ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$oldStatus[$i]\n";							# this run time will never change anymore. 

		# a failed job is now pending 
		}elsif ( ($status1 eq "FAILED") && ($status2 eq "PENDING") ) {
			print "\tCHECK: $jobID1 failed before $howOftenFailed1 times and is now pending again ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";
			
		# a failed job is now running
		}elsif ( ($status1 eq "FAILED") && ($status2 eq "RUNNING") ) {
			print "\tCHECK: $jobID1 failed before $howOftenFailed1 times and is now running again ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";

		# a failed job is still failed (was not pushed again. In case of being pushed again, we set the status to PEND)
		}elsif ( ($status1 eq "FAILED") && ($status2 eq "FAILED") ) {
			print "\tCHECK: $jobID1 failed before $howOftenFailed1 times and was not repushed ($status1 --> $status2)\n" if ($verbose);
			if ($howOftenFailed1 < $maxNumResubmission) {
				# push the job if noResubmitIfQueueMaxTimeExceeded is not set OR if the job did not exceed the runtime limit
				if ($noResubmitIfQueueMaxTimeExceeded == 0 || doesCrashedJobReachedRuntimeLimit($jobID2) == 0) {
					push @jobIDsFailedLessThanMaxNumResubmission, $jobID1;
					$allnumFailedLessThanMaxNumResubmission ++;	
				}else{
					print "\t--> Do not push this job again because it crashed by exceeding the queue runtime and noResubmitIfQueueMaxTimeExceeded is set! (set #crashes to $maxNumResubmission)\n" if ($verbose);
					$howOftenFailed1 = $maxNumResubmission;	
				}
			}
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";

		# ERROR
		}else{
			die "######### ERROR ######### in check: $oldStatus[$i] --> $newStatus[$i] is a case that is not covered\n";
		}
	}
	close fileStatus;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	
	
	my $numJobs = $allnumRun + $allnumPend + $allnumFailed + $allnumDone;

	# sanity check. If you run para make, we know how many jobs we have pushed. Compare. 
	print STDERR "######### ERROR #########: totalNoJobsPushed != numJobs ($totalNoJobsPushed != $numJobs) in check()\n" if ($totalNoJobsPushed != -1 && $totalNoJobsPushed != $numJobs);

	# flag if everything succeeded or some failed repeatedly
	# 0 means not finished, 
	# 1 all completed successfully
	# -1 no jobs are running and all either succeeded or failed repeatedly (no job could be repushed due to failing $maxNumResubmission times already)
	# -2 all jobs either succeeded or failed but failed jobs could be repushed
	my $allDone = 0;
	$allDone = 1  if ($allnumDone == $numJobs);
	$allDone = -1 if ($allnumDone + $allnumFailed == $numJobs && $allnumFailed > 0 && $allnumFailedLessThanMaxNumResubmission == 0);
	$allDone = -2 if ($allnumDone + $allnumFailed == $numJobs && $allnumFailed > 0 && $allnumFailedLessThanMaxNumResubmission > 0);
	
	if ($verbose) {
		print "CHECK: current content of $paraStatusFile\n"; 
		system("cat $paraStatusFile");
	}

	return ($allDone, $allnumRun, $allnumPend, $allnumFailed, $allnumDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, \@jobIDsFailedLessThanMaxNumResubmission);
}


#####################################################
# get status and run time of a single jobID
#####################################################
sub runSingleJob_sacct {
    my ($jobID) = shift;
    
    # run sacct and parse
    my $call = "sacct --format=JobID,State,cputimeraw,exitcode -n --delimiter=\$'\\t' -p -j $jobID";
    print "\tsingleJob sacct: $call\n" if ($verbose);
    my @res = `$call`;
    die "######### ERROR ######### in singleJob sacct: $call failed with exit code $?\n" if ($? != 0);
    chomp(@res);
    
    # just in case we get more than one line back
    foreach my $line (@res) {
        my ($jobIDreturned, $status, $runTime, $exitCode) = (split(/\t/, $line))[0,1,2,3];
        if ($jobID == $jobIDreturned) {
            return ($status, $runTime, $exitCode);
        }
    }
    die "######### ERROR ######### in $call returned this output which does not contain jobID $jobID: ",@res,"\n";
}


#####################################################
# test if the given job crashed because it reached the run time limit of this queue
# by checking if sacct returns TIMEOUT
#####################################################
sub doesCrashedJobReachedRuntimeLimit {
	my ($jobID) = @_;
    
    my ($status, $runTime, $exitCode) = runSingleJob_sacct($jobID);
    if ($status eq "TIMEOUT") {
        print "TIMEOUT Reached for $jobID\n" if ($verbose);
        return 1;
    }else{
        return 0;
    }
}

#####################################################
# Push failed jobs again until they failed $maxNumResubmission times. 
#####################################################
sub pushCrashed {
	my $crashedJobIDs = shift;			# this is a pointer to an array of crashed jobIDs generated by check()
	getLock();

	# read the bsub parameters
	open (filePara, "$paraSbatchParaFile") || die "######### ERROR #########: cannot read $paraSbatchParaFile\n";
	my $allothersbatchParameters = <filePara>;			# contains the queue and additional stuff
	close filePara;

	# now read all jobs from $paraJobsFile into a hash, as we have to update the jobIDs
	open (fileJobs, "$paraJobsFile") || die "######### ERROR #########: cannot read $paraJobsFile\n";
	print "\tPUSHCRASHED: reading $paraJobsFile .... " if ($verbose);
	my %jobID2job;
	my %jobID2name;
	my %jobID2queue;
	my $line = "";
	while ($line = <fileJobs>) {
		chomp($line);

		# format is $jobID $jobName $queue $job			(e.g. 513650	test/1/o.50	short	tests/DieRandom.perl -T 0.9 > out/15.txt)
		my ($jobID, $jobName, $queue, $job) = (split(/\t/, $line))[0,1,2,3];
		$jobID2job{$jobID} = $job;
		$jobID2name{$jobID} = $jobName;
		$jobID2queue{$jobID} = $queue;
	}
	close fileJobs;
	print "DONE\n" if ($verbose);
	
	# now push all crashed jobs again
	# store the conversion oldID -> newID in a hash
	my %oldID2newID;
	my $numJobsPushedAgain = 0;
	for (my $i=0; $i < scalar @{$crashedJobIDs}; $i++) {
		my $oldID = $crashedJobIDs->[$i];
		my $job = $jobID2job{$oldID};
		my $jobName = $jobID2name{$oldID};
		my $queueForThisJob = $jobID2queue{$oldID};
		
		print "\tPUSHCRASHED:  push again failed job with ID $oldID to queue $queueForThisJob: $job\n" if ($verbose);

		# test if this job crashed because it reached the run time limit for the specified queue
		# if this is the case, push the job to next longer queue
		if (doesCrashedJobReachedRuntimeLimit($oldID) == 1) {
			# get the next longest queue in case of reaching the runtime limit
			print "\t\tPUSHCRASHED: job $oldID reached runtime limit of $queueForThisJob and is now pushed to " if ($verbose);
			if ($queueForThisJob ne $maxRunTimeQueue) {
				# only set the queue to the next longest queue if this parameter is not given
				if ($resubmitToSameQueueIfQueueMaxTimeExceeded == 0) {
					$queueForThisJob = $Order2Queue{ $Queue2Order{$queueForThisJob} + 1 }; 
				}
			}else{
				print STDERR "ERROR: job $oldID reached runtime limit of $queueForThisJob which is the maximum runtime queue !! --> Will push again to the same queue. \n";
			}
			print "$queueForThisJob\n" if ($verbose);
		}

		# save the output file if we resubmit so that people can have a look
		system("mv ./.para/$jobName ./.para/$jobName.crashed");

		my $jobFileFixedPart = $allothersbatchParameters;
		# add runtime, depending on the queue
		if ($queueForThisJob eq "short") {
			$jobFileFixedPart .= "#SBATCH --time=01:00:00\n";
		}elsif ($queueForThisJob eq "shortmed") {
			$jobFileFixedPart .= "#SBATCH --time=03:00:00\n";
		}elsif ($queueForThisJob eq "medium") {
			$jobFileFixedPart .= "#SBATCH --time=08:00:00\n";
		}elsif ($queueForThisJob eq "day") {
			$jobFileFixedPart .= "#SBATCH --time=24:00:00\n";
		}elsif ($queueForThisJob eq "long") {
			# 2 weeks
			$jobFileFixedPart .= "#SBATCH --time=336:00:00\n";
			$jobFileFixedPart .= "#SBATCH --partition=long\n";
		}else {
			die "ERROR: queue is neither short/shortmed/medium/day/long.\n";
		}

		# push
		my $newID = pushSingleJob($jobFileFixedPart, "./.para/$jobName", $job);
		$oldID2newID{$oldID} = $newID;

		# update the jobID for the $paraJobsFile file
		delete $jobID2job{$oldID};
		$jobID2job{$newID} = $job;
		delete $jobID2name{$oldID};
		$jobID2name{$newID} = $jobName;
		delete $jobID2queue{$oldID};
		$jobID2queue{$newID} = $queueForThisJob;
		print "\tPUSHCRASHED:   --> new ID $newID\n" if ($verbose);

		$numJobsPushedAgain ++;
	}

	# write the new $paraJobsFile file that has the up-to-date jobIDs
	backup();
	open (fileJobs, ">$paraJobsFile") || die "######### ERROR #########: cannot create $paraJobsFile\n";
	print "\tPUSHCRASHED: write updated jobIDs to $paraJobsFile .... " if ($verbose);
	foreach my $jobID (sort keys %jobID2job) {
		print fileJobs "$jobID\t$jobID2name{$jobID}\t$jobID2queue{$jobID}\t$jobID2job{$jobID}\n";
	}
   close fileJobs;
	print "DONE\n" if ($verbose);

	# read the $paraStatusFile file
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my @oldStatus = <fileStatus>;
	chomp(@oldStatus);
	close fileStatus;

	# now clobber the $paraStatusFile file and update 
	# every repushed job gets the new ID and gets status PEND. Runtime is set to -1
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot create $paraStatusFile\n";
	print "\tPUSHCRASHED: update $paraStatusFile .... \n" if ($verbose);
	for (my $i=0; $i<=$#oldStatus; $i++) {
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];
		if (exists $oldID2newID{$jobID}) { 
			my $newStatus = "$oldID2newID{$jobID}\t$jobName\tPENDING\t$howOftenFailed\t-1";
			print "\t\tPUSHCRASHED: OLD $oldStatus[$i]\n\t\tPUSHCRASHED: NEW $newStatus\n" if ($verbose);
			print fileStatus "$newStatus\n";
		}else{
			# a job that we have not touched
			print fileStatus "$oldStatus[$i]\n";	
		}
	}
	close fileStatus;
	print "\tPUSHCRASHED: DONE\n" if ($verbose);

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "--> $numJobsPushedAgain jobs crashed and were pushed again\n";
}

#####################################################
# wait until the joblist is done. Push failed jobs again until they failed $maxNumResubmission times. 
#####################################################
sub waitForJobs {

	print "WAIT UNTIL jobList is finished ..... \n";

	# number of sleep cycles. Used to increase the cycle length after a $\
	my $noSleepCycles = 0;
	
	# count how long we are waiting
	my $totalWaitTime = 0;
	
	while (1) {
		# for sanity purpose only
		checkIfInternalFilesExist($jobListName);
		
		# now check how many are done
		# allDone is a flag: 1 == all done, 0 == some run/pend/failed, -1 == some jobs failed repeatedly but all others are done, -2 == all jobs finished or crashed but the crashed ones can be resubmitted
		my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $numFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
		printf "numJobs: %-7d\tRUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d  (%d of them failed $maxNumResubmission times)\tallDone: %s\n", $numJobs,$numRun,$numPend,$numDone,$numFailed,$numFailed-$numFailedLessThanMaxNumResubmission,($allDone == 1 ? "YES" : "NO");	
		
		if ($allDone == 1) {
			print "*** ALL JOBS SUCCEEDED ***\n";
			last;
		}elsif ($allDone == -1) {
			print "*** CRASHED. Some jobs failed $maxNumResubmission times !!  Run 'para crashed' to list those failed jobs. ***\n";
			last;
		}
		
		# push crashed jobs again, if some failed less than $maxNumResubmission times
		pushCrashed($jobIDsFailedLessThanMaxNumResubmission) if ($numFailedLessThanMaxNumResubmission > 0);

		# sleep. At the beginning we sleep only a minute, after 10 minutes, we sleep 3 minutes. All are parameters
		if ($noSleepCycles >= $maxNumFastSleepCycles) {
			print "sleep $sleepTime2 seconds ...  (waiting $totalWaitTime sec by now)\n";
			$totalWaitTime += $sleepTime2;
			sleep($sleepTime2);
		}else{
			print "sleep $sleepTime1 seconds ...  (waiting $totalWaitTime sec by now)\n";
			$totalWaitTime += $sleepTime1;
			sleep($sleepTime1);
		}
		$noSleepCycles ++;
	}	

	printf "totalWaitTime waited: %d sec  ==  %1.1f min  ==  %1.1f h  ==  %1.1f days\n", $totalWaitTime, $totalWaitTime/60, $totalWaitTime/60/60, $totalWaitTime/60/60/24; 

}	


#####################################################
# run sacct and parse
#####################################################
sub runsacct {
	my ($IDstring) = @_;
	
	# sanity check: We should get one result line from sacct for every given ID. If not, we are losing jobs. 
	# we put all returned jobIDs in a hash and check at the end if all IDs have been returned
	my %jobIDsSeen;
		
	# run sacct
	my $call = "sacct --format=JobID,State,cputimeraw,exitcode -n --delimiter=\$'\\t' -p -j $IDstring";
	print "\tRUNsacct: $call\n" if ($verbose);
	my @res = `$call`;
	die "######### ERROR ######### in runsacct: $call failed with exit code $?\n" if ($? != 0);
	print "\tresult $?: @res\n" if ($verbose);
	chomp(@res);
		
	# parse something like 
	# 65377         COMPLETED   00:00:00      0:0
	# 65377.0       COMPLETED   00:00:00      0:0
	# 65380         COMPLETED   00:00:00      0:0
	# 65390         COMPLETED   00:01:40      0:0
	my $parajob = "";	   # string holding "JobID status numfailed runtime"
	my $numRun = 0;
	my $numPend = 0;
	my $numFailed = 0;
	my $numDone = 0;
	foreach my $line (@res) {
		print "\t\tRUNsacct current line: $line\n" if ($verbose);
		my ($jobID, $status, $runTime, $exitCode) = (split(/\t/, $line))[0,1,2,3];
		print "\t\t\tparse: $jobID, $status, $runTime, $exitCode   from line: $line\n" if ($verbose);
		# exclude these lines
		# 65377.0      echo "hal+  COMPLETED   00:00:00      0:0
		if ($jobID =~ /\./) {
			print "\t\t\tline contains a .0 jobID $jobID\n" if ($verbose);
			next;
		}
		$jobIDsSeen{$jobID} = 1;
		# simplify some Slurm status'es
		$status = "FAILED" if ($status =~ /^CANCELLED/);
		$status = "FAILED" if ($status eq "NODE_FAIL");
		$status = "RUNNING " if ($status eq "PREEMPTED");
		$status = "FAILED" if ($status eq "TIMEOUT");
		$status = "RUNNING" if ($status eq "RESIZING");
		$status = "RUNNING" if ($status eq "SUSPENDED");
		$status = "RUNNING" if ($status eq "COMPLETING");
		
		$parajob .= "$jobID\tdummyName\t$status\t0\t-1\n";

		$numRun ++ if ($status eq "RUNNING");
		$numPend ++ if ($status eq "PENDING");
		$numFailed ++ if ($status eq "FAILED");
		$numDone ++ if ($status eq "COMPLETED");

		die "ERROR: unknown status: $status\n" if ($status ne "RUNNING" && $status ne "PENDING" && $status ne "FAILED" && $status ne "COMPLETED");

	}
		
	print "\tRUNsacct result:	 RUN: $numRun\t\tPEND: $numPend\t\tDONE: $numDone\t\tFAILED: $numFailed	  and as the following status lines...\n$parajob\n" if ($verbose);
	
	# now check if all given IDs were returned by sacct
	foreach my $ID (split(/,/, $IDstring)) {
		print STDERR "######### ERROR ######### in runsacct: $ID was given in the input but sacct did not return anything for that ID\n" if (! exists $jobIDsSeen{$ID});
	}
	
	return ($parajob, $numRun, $numPend, $numFailed, $numDone);
}
	
	

#####################################################
# recover the crashed jobs and write them to the given output file
#####################################################
sub crashed {

	my $outjobListFile = $ARGV[2];
	print "\tCRASHED: recover jobIDs of crashed jobs\n" if ($verbose);

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();

	getLock();

	# get all crashed jobIDs from $paraStatusFile
	# create a hash that lists these jobIDs
	my %crashedJobIDs;
	my $numCrashed = 0;
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my $line = "";
	while ($line = <fileStatus>) {
		chomp($line);

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $line))[0,1,2,3,4];
		if ($status eq "FAILED") {
			print "\t\tCRASHED: $line\n" if ($verbose);
			$crashedJobIDs{$jobID} = 1;
			$numCrashed ++;
		}
	}
    close fileStatus;
	print "\tCRASHED: found $numCrashed jobIDs that crashed\n" if ($verbose);

   # now read all jobs from $paraJobsFile and output the crashed ones into the output file
	open (fileJobs, "$paraJobsFile") || die "######### ERROR #########: cannot read $paraJobsFile\n";
	open (fileOut, ">$outjobListFile") || die "######### ERROR #########: cannot create $outjobListFile\n";
	print "\tCRASHED: open $outjobListFile\n" if ($verbose);
	while ($line = <fileJobs>) {
		chomp($line);

		# format is $jobID $jobName $job
		my ($jobID, $jobName, $queue, $job) = (split(/\t/, $line))[0,1,2,3];
		if (exists $crashedJobIDs{$jobID}) {
			print "\t\tCRASHED: crashed job $job	(line from $paraJobsFile: $line)\n" if ($verbose);
			print fileOut "$job\n";
		}
	}
	close fileJobs;
	close fileOut;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "recovered $numCrashed crashed jobs into $outjobListFile\n";
}


#####################################################
# kills all pending jobs if "chill" is given
# kills all pending AND running jobs if "stop" is given
#####################################################
sub killJobs {
	my $mode = shift; 		# is either stop or chill

	print "\tKILLJOBS: mode $mode\n" if ($verbose);

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();

	getLock();

	# get all jobIDs and their status from $paraStatusFile
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my $line = "";
	while ($line = <fileStatus>) {
		chomp($line);

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $line))[0,1,2,3,4];
		if ($status eq "PENDING") {
			print "\t\tKILL pending job: $line\n" if ($verbose);
			system "scancel $jobID" || print "######### ERROR #########: 'scancel $jobID' caused an error. Did the job already finish ?";
		}elsif ($status eq "RUNNING" && $mode eq "stop") {
			print "\t\tKILL running job: $line\n" if ($verbose);
			system "scancel $jobID" || print "######### ERROR #########: 'scancel $jobID' caused an error. Did the job already finish ?";
		}
	}
	close fileStatus;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "$numPend pending ", ($mode eq "stop" ? "and $numRun running " : ""), "jobs killed\n";
}


#####################################################
# get run times of all running and done jobs. Estimate when the jobList will be finished
#####################################################
sub gettime {
	print "\tGETTIME:\n" if ($verbose);

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	
	getLock();

	# read the $paraStatusFile file
	# if a job is running, get the current run time
	# if a job is finished, read the total run time for that job from the file OR if not given, get the total run time
	# then update $paraStatusFile and calculate the stats
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my @oldStatus = <fileStatus>;
	chomp(@oldStatus);
	close fileStatus;
	if ($verbose) {
		$" = "\n\t"; print "\t\tGETTIME: old Status array:\n\t@oldStatus\n";
	}

	my $newStatus = "";	# string that contains the new content of $paraStatusFile
	my @timesFinished;	# runtimes of finished jobs
	my @timesRunning;		# current runtimes of running jobs
	my $runTimeLongestRunningJob = -1;			# runtime of longest running job
	my $jobIDMaxRunTimeRunning = -1;				# jobID of this job
	my $runTimeLongestFinishedJob = -1;			# runtime of longest finished job
	my $jobIDMaxRunTimeFinished = -1;			# jobID of this job
	for (my $i=0; $i<=$#oldStatus; $i++) {

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];

		# just copy pending or crashed jobs
		if ($status eq "FAILED" || $status eq "PENDING") {
			$newStatus .= "$oldStatus[$i]\n";
			print "\t\tGETTIME: skip $oldStatus[$i]\n" if ($verbose);

		}elsif ($status eq "COMPLETED") {
			# check() does not update but writes -1 for all jobs that finished, expect those that finished before and had a correct runtime already given.
			# therefore we have to get the runtime, if the given runtime in the file is -1. 
			# Once we put the correct runtime in the $paraStatusFile file, we never have to get it again sacct
			print "\t\tGETTIME: finished job $oldStatus[$i]\n" if ($verbose);
			if ($runTime == -1) {
				$runTime = getRunTime($jobID);
			}
			push @timesFinished, $runTime;
			$newStatus .= "$jobID\t$jobName\t$status\t$howOftenFailed\t$runTime\n";
			# longest finished job
			if ($runTimeLongestFinishedJob < $runTime) {
				$runTimeLongestFinishedJob = $runTime;
				$jobIDMaxRunTimeFinished = $jobID;	
			}

		}elsif ($status eq "RUNNING") {
			# we always measure the runtime of currently running jobs again
			$runTime = getRunTime($jobID);
			print "\t\tGETTIME: running job $oldStatus[$i]  time: $runTime\n" if ($verbose);
			push @timesRunning, $runTime;
			$newStatus .= "$jobID\t$jobName\t$status\t$howOftenFailed\t$runTime\n";

			# longest running job
			if ($runTimeLongestRunningJob < $runTime) {
				$runTimeLongestRunningJob = $runTime;
				$jobIDMaxRunTimeRunning = $jobID;	
			}
	
		}else {		# sanity check
			die "######### ERROR ######### in gettime: unknown status: $oldStatus[$i]\n$paraStatusFile is not altered.";
		}
	}

	# now update $paraStatusFile with the new runtimes
 	backup();
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot write $paraStatusFile\n";
	print fileStatus "$newStatus";
	close fileStatus;

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	# now calculate the stats and print
	my $ave = -1;
	my $sum = -1;
	$sum = getSum(@timesFinished) if ($#timesFinished >= 0);
	$ave = $sum / (scalar @timesFinished) if ($#timesFinished >= 0);
	printf "RUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d\n", $numRun,$numPend,$numDone,$numFailed;	
	if ($ave == -1) {
		printf "%-25s NO job finished. No estimate.\n", "Average job time:";	
	}else{
		printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\n", "Time in finished jobs:", $sum, $sum/60, $sum/60/60, $sum/60/60/24;
		printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\n", "Average job time:", $ave, $ave/60, $ave/60/60, $ave/60/60/24;
	}
	printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\t\t(jobID $jobIDMaxRunTimeFinished)\n", "Longest finished job:", $runTimeLongestFinishedJob, $runTimeLongestFinishedJob/60, $runTimeLongestFinishedJob/60/60, $runTimeLongestFinishedJob/60/60/24 if ($runTimeLongestFinishedJob > 0);
	printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\t\t(jobID $jobIDMaxRunTimeRunning)\n", "Longest running job:", $runTimeLongestRunningJob, $runTimeLongestRunningJob/60, $runTimeLongestRunningJob/60/60, $runTimeLongestRunningJob/60/60/24 if ($runTimeLongestRunningJob > 0);
	# estimated time to completion == $ave * ($numPend + $numRun) / $numRun
	# we assume here that the running and pending jobs will have a similar run time and that we will continue to use the same number cores ($numRun)
	# this estimate is conservative in that all running jobs are assumed to take $ave time to completion (ignores that they are running already)
	if ($allDone == 1) {
		print "*** ALL JOBS SUCCEEDED ***\n";
	}elsif ($allDone == -1) {
		print "*** CRASHED. Some jobs failed $maxNumResubmission times !!  Run 'para crashed' to list those failed jobs. ***\n";
	}else {
		if ($numRun == 0) {
			printf "%-25s INFINITE as no jobs are running but only $numDone of $numJobs succeeded\n", "Estimated complete:";
		}else{
			my $estimatedComplete = $ave * ($numPend + $numRun) / $numRun;
			printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\t\t(assume $numRun running jobs)\n", "Estimated complete:", $estimatedComplete, $estimatedComplete/60, $estimatedComplete/60/60, $estimatedComplete/60/60/24;;
		}
	}
}


#####################################################
# get run times of a job, given its jobID
#####################################################
sub getRunTime {
	my ($jobID) = @_;

	print "\t\tGETRUNTIME for $jobID\n" if ($verbose);
    
    my ($status, $runTime, $exitCode) = runSingleJob_sacct($jobID);
	return $runTime;
}


#####################################################
# delete all para and LSF output files for $jobListName
#####################################################
sub clean {

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();

	die "######### ERROR #########: you still have $numRun running and $numPend pending jobs. Before cleaning, you have to run 'para stop $jobListName' to stop all jobs.\n" if ($numRun > 0 || $numPend > 0);

	getLock();

	# get all jobNames and remove .para/$jobName
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my $line = "";
	while ($line = <fileStatus>) {
		chomp($line);

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $line))[0,1,2,3,4];
		system("rm -f ./.para/$jobName");
	}   
	close fileStatus;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	system("rm -f $paraStatusFile $paraJobsFile $paraSbatchParaFile $paraJobNoFile $paraStatusFilebackup* $paraJobsFilebackup* $paraSbatchParaFilebackup*");
	system("rm -rf ./.para/$jobListName");
	
	# delete .para/backup directory if it is empty
	if (-d ".para/backup") {
		system ("rmdir .para/backup") if (`ls .para/backup | wc -l` eq "0\n"); 
	}

	# delete .para directory if it is empty
	system ("rmdir .para") if (`ls .para/ | wc -l` eq "0\n"); 

	print "jobList $jobListName is cleaned\n";
}

=pod
#####################################################
# restore the .para/.para.*.$jobListName files from the backup files
#####################################################
sub restore {

	die "The restore() function is currently disabled as we are storing all backup files in the .para/backup/ dir right now
Please look into .para/backup/ and get the version that still has uncorrupted data (highest version numbers are most recent data)
Then copy the respective backup files to $paraStatusFile $paraJobsFile $paraSbatchParaFile
Version 0 refers to the files that have been created right during the first submission of the jobs
";

	if (! -e "$paraStatusFile.backup" || ! -e "$paraJobsFile.backup" || ! -e "$paraSbatchParaFile.backup") {
		die "######### ERROR #########: cannot restore the backup files as they don't exist: $paraStatusFile.backup $paraJobsFile.backup $paraSbatchParaFile.backup\n" 
	}
	
	getLock();

	system("mv $paraStatusFile.backup $paraStatusFile");
	system("mv $paraJobsFile.backup $paraJobsFile");
	system("mv $paraSbatchParaFile.backup $paraSbatchParaFile");

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "Successfully restored the internal .para files for jobList $jobListName\n";
}
=cut

#####################################################
# make a backup copy with version number 0 that refers to these original files
#####################################################
sub firstBackup {
	return if ($keepBackupFiles == 0);

	my $endNumber = 0;
	system("cp $paraStatusFile $paraStatusFilebackup$endNumber"); 
	system("cp $paraJobsFile $paraJobsFilebackup$endNumber");
	system("cp $paraSbatchParaFile $paraSbatchParaFilebackup$endNumber");
}

#####################################################
# backup the .para/.para.*.$jobListName files
# new feature: we backup every time and store the files with a unique end number
#####################################################
sub backup {
	return if ($keepBackupFiles == 0);
	
	# get the highest backup number
	my $command = "find .para/backup/ -name \".para.jobs.$jobListName.backup*\" | awk -F\"backup\" '{print \$3}' | sort -g | tail -n 1";
	print "backup function: running $command\n" if ($verbose);
	
	my $endNumber = 1;
	$endNumber = `$command`;
	chomp($endNumber);
	$endNumber++;
	print "backup function: new endNumber is $endNumber for $paraJobsFilebackup*\n" if ($verbose);

	system("cp $paraStatusFile $paraStatusFilebackup$endNumber"); 
	system("cp $paraJobsFile $paraJobsFilebackup$endNumber");
	system("cp $paraSbatchParaFile $paraSbatchParaFilebackup$endNumber");

}

#########################################################################################################
# compute sum of vector
#########################################################################################################
sub getSum {
	my @vector = @_;
	if ($#vector < 0) {
		print STDERR "ERROR: empty vector for getSum\n";
		return -10000000000;
	}

	my $sum = 0;
	my $count = 0;	
	for (my $i=0; $i<=$#vector; $i++) {
		$sum += $vector[$i];
		$count++;
	}
	return $sum;
}


