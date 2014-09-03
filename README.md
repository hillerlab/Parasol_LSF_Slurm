ParasolLSF
==========

A wrapper around LSF for managing batches of jobs (jobLists) on a compute cluster.

The wrapper is inspired by Jim Kent's Parasol functionality (http://genecats.cse.ucsc.edu/eng/parasol.htm).

This wrapper script (para.pl) can submit, monitor and wait until an entire jobList is finished. It can output average runtime statistics and estimates when the entire jobList should be finished. It can recover crashed jobs and submit them again. It can stop all the running&pending or only the pending jobs of this jobList only. Finally, in complex pipelines (see below), you can string together more than one jobList. Because you need to specify a unique name for each running jobList, it is easy to manage more than one jobList.

Please see README.html for much more details and how to use it. 
