ABOUT!
This app is a collection of macros and saved searches to assist with monitoring custom search-time configuration across a federated search environment.

INSTALLATION LOCATION
This should be installed on search heads involved in federated searches. This includes all remote servers, as well as the primary federated search head.

REMOTE SEARCH HEADS
All macros intended for use on the remote search heads are prefixed with "conf". See any of the `conf_search` macros for instructions on how to use.
Saved searches have also been created for the common configuration endpoints that need to be collected and can be enabled for use. Please note there are some pre-requisites to executing these, all of which are detailed in the conf_search macros
IMPORTANT... make sure that the saved searches are executed by the service account used when setting up the federated provider. These should also be executed within the same app as the provider

FEDERATED SEARCH HEADS
All macros intended for use on the federated search head are prefixed with "fedsearch". See any of the `fedsearch_confalert_get` macros for full instructions on how to use these, prerequisites, and usage examples. 
There are no pre-built saved searches due to the varied nature of each customer environment. To build your search(es) you are likely only going to need to specify the appropriate version of the fedsearch_confalert_get macro for each configuration item. Every macro has a header atop to explain its purpose and whether they need to / should be modified.