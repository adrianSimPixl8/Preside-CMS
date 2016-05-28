/**
 * @singleton
 *
 */
component {

// CONSTRUCTOR
	/**
	 * @configWrapper.inject              taskManagerConfigurationWrapper
	 * @controller.inject                 coldbox
	 * @taskDao.inject                    presidecms:object:taskmanager_task
	 * @taskHistoryDao.inject             presidecms:object:taskmanager_task_history
	 * @systemConfigurationService.inject systemConfigurationService
	 * @cfThreadHelper.inject             cfThreadHelper
	 * @logger.inject                     logbox:logger:taskmanager
	 * @errorLogService.inject            errorLogService
	 * @siteService.inject                siteService
	 *
	 */
	public any function init(
		  required any configWrapper
		, required any controller
		, required any taskDao
		, required any taskHistoryDao
		, required any systemConfigurationService
		, required any cfThreadHelper
		, required any logger
		, required any errorLogService
		, required any siteService
	) {
		_setConfiguredTasks( arguments.configWrapper.getConfiguredTasks() );
		_setController( arguments.controller );
		_setTaskDao( arguments.taskDao );
		_setTaskHistoryDao( arguments.taskHistoryDao );
		_setSystemConfigurationService( arguments.systemConfigurationService );
		_setCfThreadHelper( cfThreadHelper );
		_setLogger( arguments.logger );
		_setErrorLogService( arguments.errorLogService );
		_setSiteService( arguments.siteService );

		_initialiseDb();

		return this;
	}

// PUBLIC API METHODS
	public array function listTasks() {
		return _getConfiguredTasks().keyArray();
	}

	public struct function getTask( required string taskKey ) {
		var tasks = _getConfiguredTasks();

		return tasks[ arguments.taskKey ] ?: throw( type="TaskManager.missing.task", message="Task [#arguments.taskKey#] does not exist. Existing tasks are: #SerializeJson( listTasks() )#" );
	}

	public struct function getTaskConfiguration( required string taskKey ) {
		var task        = getTask( arguments.taskKey );
		var taskDetails = _getTaskDao().selectData(
			  filter       = { task_key=arguments.taskKey }
			, selectFields = [ "crontab_definition", "enabled" ]
		);

		for( var t in taskDetails ) {
			if ( !Len( Trim( t.crontab_definition ) ) ) {
				t.crontab_definition = task.schedule;
			}

			return t;
		}

		return {};
	}

	public void function saveTaskConfiguration( required string taskKey, required struct config  ) {
		_getTaskDao().updateData(
			  filter = { task_key=arguments.taskKey }
			, data   = arguments.config
		);

		_getTaskDao().updateData(
			  filter = { task_key=arguments.taskKey }
			, data   = { next_run = getNextRunDate( arguments.taskKey ) }
		);
	}

	public string function getValidationErrorMessageForPotentiallyBadCrontabExpression( required string crontabExpression ) {
		try {
			_getCrontabExpressionObject( arguments.cronTabExpression );
		} catch ( any e ) {
			return e.message;
		}

		return "";
	}

	public boolean function taskExists( required string taskKey ) {
		return 	_getConfiguredTasks().keyExists( arguments.taskKey );
	}

	public boolean function tasksAreRunning() {
		var areRunning = false;

		for( var taskKey in listTasks() ){
			var taskRunning = taskIsRunning( taskKey );
			areRunning = areRunning || taskRunning;
		}

		return areRunning;
	}

	public boolean function taskIsRunning( required string taskKey ) {
		transaction {
			if ( taskRunIsExpired( arguments.taskKey ) ) {
				var logger = _getLogger( taskKey=arguments.taskKey );

				if ( logger.canError() ) {
					logger.error( "Task run has expired for task [#arguments.taskKey#]." )
				}

				markTaskAsCompleted(
					  taskKey   = arguments.taskKey
					, success   = false
					, timetaken = -1
				);

				return false;
			}
			var markedAsRunning = _getTaskDao().dataExists( filter = { task_key=arguments.taskKey, is_running=true } );

			if ( markedAsRunning && !taskThreadIsRunning( arguments.taskKey ) ) {
				var logger = _getLogger( taskKey=arguments.taskKey );

				if ( logger.canError() ) {
					logger.error( "Task was marked as running but task thread is no longer running." );
				}

				markTaskAsCompleted(
					  taskKey   = arguments.taskKey
					, success   = false
					, timetaken = -1
				);
				return false;
			}

			return markedAsRunning;
		}
	}

	public boolean function taskRunIsExpired( required string taskKey ) {
		return _getTaskDao().dataExists(
			  filter       = "task_key = :task_key and is_running = :is_running and run_expires < :run_expires"
			, filterParams = { task_key=arguments.taskKey, is_running=true, run_expires=_getOperationDate() }
		);
	}

	public boolean function taskThreadIsRunning( required string taskKey ) {
		var task = _getTaskDao().selectData(
			  selectFields = [ "running_thread" ]
			, filter       = { task_key=arguments.taskKey }
		);

		if ( !task.recordCount || !Len( Trim( task.running_thread ) ) ) {
			return false;
		}

		var runningStatuses = [ "RUNNING", "NOT_STARTED" ];
		var threads         = _getCfThreadHelper().getRunningThreads();

		return runningStatuses.find( threads[ task.running_thread ].status ?: "" );
	}

	public array function getRunnableTasks() {
		if ( tasksAreRunning() ) {
			return [];
		}

		var runnableTasks = _getTaskDao().selectData(
			  selectFields = [ "task_key" ]
			, filter       = "enabled = :enabled and is_running = :is_running and next_run < :next_run"
			, filterParams = { enabled = true, is_running = false, next_run = _getOperationDate() }
			, orderBy      = "priority desc"
			, maxRows      = 1
		);

		return runnableTasks.recordCount ? ValueArray( runnableTasks.task_key ) : [];
	}

	public void function runTask( required string taskKey ) {
		var task        = getTask( arguments.taskKey );
		var success     = true;
		var newThreadId = "PresideTaskmanagerTask-" & arguments.taskKey & "-" & CreateUUId();
		var newLogId    = createTaskHistoryLog( arguments.taskKey, newThreadId );
		var lockName    = "runtask-#taskKey#" & Hash( ExpandPath( "/" ) );

		lock name=lockName type="exclusive" timeout="1" {
			transaction {
				if ( taskIsRunning( arguments.taskKey ) ) {
					return;
				}

				markTaskAsRunning( arguments.taskKey, newThreadId );
			}

			thread name=newThreadId priority="high" taskKey=arguments.taskKey event=task.event taskName=task.name logger=_getLogger( newLogId ) processTimeout=task.timeout {
				setting requesttimeout = attributes.processTimeout;

				var start = getTickCount();

				try {
					success = _getController().runEvent(
						  event          = attributes.event
						, private        = true
						, eventArguments = { logger=attributes.logger }
					);
				} catch( any e ) {
					setting requesttimeout=55;

					if ( attributes.logger.canError() ) {
						attributes.logger.error( "An error occurred running task [#attributes.taskName#]. Message: [#e.message#], detail [#e.detail#].", e );
					}

					_getErrorLogService().raiseError( e );

					success = false;
					rethrow;
				} finally {
					try {
						markTaskAsCompleted(
							  taskKey   = attributes.taskKey
							, success   = success
							, timeTaken = GetTickCount() - start
						);
					} catch( any e ) {
						setting requesttimeout=55;

						if ( attributes.logger.canError() ) {
							attributes.logger.error( "An error occurred running task [#attributes.taskName#]. Message: [#e.message#], detail [#e.detail#].", e );
						}

						_getErrorLogService().raiseError( e );

						success = false;
						rethrow;
					}
				}
			}
		}
	}

	public boolean function killRunningTask( required string taskKey ) {
		var task = _getTaskDao().selectData(
			  selectFields = [ "running_thread" ]
			, filter = { task_key=arguments.taskKey }
		);

		if ( task.recordCount && Len( Trim( task.running_thread ) ) ) {
			var logger = _getLogger( taskKey=arguments.taskKey );
			if ( logger.canWarn() ) {
				logger.warn( "Task manually cancelled by user. Killing task thread now..." );
			}
			_getCfThreadHelper().terminateThread( task.running_thread );
		}

		return !taskIsRunning( taskKey );
	}

	public array function listTasksStoredInStatusDb() {
		var taskRecords = _getTaskDao().selectData( selectFields=[ "task_key" ] );

		return taskRecords.recordCount ? ValueArray( taskRecords.task_key ) : [];
	}

	public void function ensureTasksExistInStatusDb() {
		var existingTasksInDb = listTasksStoredInStatusDb();
		var configuredTasks   = listTasks();

		for( var task in configuredTasks ){
			if ( !existingTasksInDb.find( task ) ) {
				addTaskToStatusDb( task );
			}
		}

		for( var task in existingTasksInDb ) {
			if ( !configuredTasks.find( task ) ) {
				removeTaskFromStatusDb( task );
			}
		}
	}

	public numeric function markTaskAsRunning( required string taskKey, required string threadId ) {
		return _getTaskDao().updateData(
			  data   = { is_running=true, next_run=getNextRunDate( arguments.taskKey ), run_expires=getTaskRunExpiry( arguments.taskKey ), running_thread = arguments.threadId }
			, filter = { task_key = arguments.taskKey }
		);
	}

	public numeric function markTaskAsCompleted( required string taskKey, required boolean success, required numeric timeTaken ) {
		completeTaskHistoryLog( argumentCollection=arguments );

		var updatedRows = _getTaskDao().updateData(
			  filter = { task_key = arguments.taskKey }
			, data   = {
				  is_running           = false
				, last_ran             = _getOperationDate()
				, next_run             = getNextRunDate( arguments.taskKey )
				, was_last_run_success = arguments.success
				, last_run_time_taken  = arguments.timeTaken
				, run_expires          = ""
				, running_thread       = ""
			  }
		);

		return updatedRows;
	}

	public string function createTaskHistoryLog( required string taskKey, required string threadId ) {
		purgeTaskHistoryLog( arguments.taskKey );

		return _getTaskHistoryDao().insertData( data={
			  task_key   = arguments.taskKey
			, thread_id  = arguments.threadId
		} );
	}

	public numeric function completeTaskHistoryLog( required string taskKey, required boolean success, required numeric timeTaken ) {
		var historyId = getActiveHistoryIdForTask( arguments.taskKey );
		if ( Len( Trim( historyId ) ) ) {
			_getTaskHistoryDao().updateData(
				  id = historyId
				, data = { complete=true, success=arguments.success, time_taken=arguments.timeTaken }
			);
		}
	}

	public string function getActiveHistoryIdForTask( required string taskKey ) {
		var task = _getTaskDao().selectData(
			  selectFields = [ "running_thread" ]
			, filter = { task_key=arguments.taskKey }
		);

		if ( Len( Trim( task.running_thread ) ) ) {
			var history = _getTaskHistoryDao().selectData( selectFields=[ "id" ], filter={ thread_id = task.running_thread } );
			if ( history.recordCount ) {
				return history.id;
			}
		}

		return "";
	}

	public numeric function purgeTaskHistoryLog( required string taskKey ) {
		var daysToKeepLogs   = Val( _getSystemConfigurationService().getSetting( "taskmanager", "keep_logs_for_days", 7 ) );
		var oldestDateToKeep = DateAdd( "d", 0-daysToKeepLogs, Now() );

		return _getTaskHistoryDao().deleteData(
			  filter       = "task_key = :task_key and datecreated < :datecreated"
			, filterParams = { task_key = arguments.taskKey, datecreated = oldestDateToKeep }
		);
	}

	public struct function runScheduledTasks() {
		var settings              = _getSystemConfigurationService().getCategorySettings( "taskmanager" );
		var scheduledTasksEnabled = settings.scheduledtasks_enabled ?: false;
		var site_context          = settings.site_context           ?: "";
		var siteSvc               = _getSiteService();

		if ( !IsBoolean( scheduledTasksEnabled ) || !scheduledTasksEnabled ) {
			return { tasksStarted=[], error="Scheduled tasks are disabled" };
		}

		if ( Len( Trim( site_context ) ) && site_context != siteSvc.getActiveSiteId() ) {
			return { tasksStarted=[], error="Scheduled tasks are not configured to run for this site context. Please review your general task manager configuration settings" };
		}

		var tasks = getRunnableTasks();

		for( var taskKey in tasks ){
			runTask( taskKey );
		}

		return { tasksStarted=tasks };
	}

	public string function addTaskToStatusDb( required string taskKey ) {
		var configuredTask = getTask( arguments.taskKey );

		return _getTaskDao().insertData( data={
			  task_key           = arguments.taskKey
			, next_run           = getNextRunDate( arguments.taskKey )
			, enabled            = true
			, is_running         = false
			, priority           = configuredTask.priority
			, crontab_definition = configuredTask.schedule
		} );
	}

	public numeric function removeTaskFromStatusDb( required string taskKey ) {
		return _getTaskDao().deleteData(
			filter = { task_key = arguments.taskKey }
		);
	}

	public string function getNextRunDate( required string taskKey, date lastRun=Now() ) {
		var task       = getTask( arguments.taskKey );
		var taskConfig = getTaskConfiguration( arguments.taskKey );
		var schedule   = Len( Trim( taskConfig.crontab_definition ?: "" ) ) ? taskConfig.crontab_definition : task.schedule;

		var cronTabExpression = _getCrontabExpressionObject( schedule );
		var lastRunJodaTime   = _createJodaTimeObject( DateAdd( 'n', 1, arguments.lastRun ) ); // add 1 minute to the time so that we don't get a mini loop of repeated task running due to interesting way the java lib calcs the next time

		return cronTabExpression.nextTimeAfter( lastRunJodaTime  ).toDate();

	}

	public void function registerMasterScheduledTask() {
		var settings = _getSystemConfigurationService().getCategorySettings( "taskmanager" );
		var enabled  = IsBoolean( settings.scheduledtasks_enabled ?: "" ) && settings.scheduledtasks_enabled;
		var action   = enabled ? "update" : "delete";
		var args     = {};

		args.task = "PresideTaskManager_" & LCase( Hash( GetCurrentTemplatePath() ) );

		if ( enabled ) {
			args.url       = _getScheduledTaskUrl( settings.site_context ?: "" );
			args.startdate = "1900-01-01";
			args.startTime = "00:00:00";
			args.interval  = "30";

			if ( cgi.server_port != 80 ) {
				args.port = cgi.server_port;
			}
		};

		schedule action=action attributeCollection=args;
	}

	public array function getAllTaskDetails() {
		var tasks       = _getConfiguredTasks();
		var taskDetails = [];
		var dbTaskInfo  = _getTaskDao().selectData(
			selectFields = [ "task_key", "enabled", "is_running", "last_ran", "next_run", "last_run_time_taken", "was_last_run_success", "crontab_definition" ]
		);

		for( var dbRecord in dbTaskInfo ){
			var detail = dbRecord;
			detail.append( tasks[ detail.task_key ] ?: {} );
			detail.schedule = _cronTabExpressionToHuman( Len( Trim( detail.crontab_definition ) ) ? detail.crontab_definition : detail.schedule );
			detail.is_running = taskIsRunning( detail.task_key );
			if( detail.is_running ){
				detail.taskHistoryId = getActiveHistoryIdForTask( detail.task_key );
			}
			taskDetails.append( detail );
		}

		taskDetails.sort( function( a, b ){
			return a.name < b.name ? -1 : 1;
		} );

		return taskDetails;
	}

	public numeric function disableTask( required string taskKey ) {
		return _getTaskDao().updateData(
			  filter = { task_key = arguments.taskKey }
			, data   = { enabled = false }
		);
	}

	public numeric function enableTask( required string taskKey ) {
		return _getTaskDao().updateData(
			  filter = { task_key = arguments.taskKey }
			, data   = { enabled = true }
		);
	}

	public date function getTaskRunExpiry( required string taskKey ) {
		var task = getTask( arguments.taskKey );

		return DateAdd( "s", task.timeout, _getOperationDate() );
	}

	public string function createLogHtml( required string log, numeric fetchAfterLines=0 ) {
		var logArray = ListToArray( arguments.log, Chr(10) );
		var outputArray = [];

		for( var i=arguments.fetchAfterLines+1; i <= logArray.len(); i++ ){
			var line = logArray[ i ];
			var logClass = LCase( ReReplace( line, '^\[(.*?)\].*$', '\1' ) );
			var dateTimeRegex = "(\[20[0-9]{2}\-[0-9]{2}\-[0-9]{2}\s[0-9]{2}:[0-9]{2}:[0-9]{2}\])";

			line = ReReplace( line, dateTimeRegex, '<span class="task-log-datetime">\1</span>' );
			line = '<span class="line-number">#i#.</span> <span class="task-log-line task-log-#logClass#">' & line & '</span>';

			outputArray.append( line );
		}

		return outputArray.toList( Chr(10) );
	}

	public struct function getStats() {
		var tasks             = _getTaskDao().selectData();
		var taskHistory       = _getTaskHistoryDao().selectData();
		var failureCount      = 0;
		var successCount      = 0;
		var totalTime         = 0;
		var historicSuccesses = 0;
		var historicFailures  = 0;

		for( var task in tasks ) {
			if ( IsBoolean( task.was_last_run_success ?: "" ) ) {
				if ( task.was_last_run_success ) {
					successCount++;
				} else {
					failureCount++;
				}
			}
		}

		for( var log in taskHistory ) {
			totalTime += Val( log.time_taken );
			if ( IsBoolean( log.success ?: "" ) ) {
				if ( log.success ) {
					historicSuccesses++;
				} else {
					historicFailures++;
				}
			}
		}

		return {
			  "taskmanager.failure.count" = failureCount
			, "taskmanager.success.count" = successCount
			, "taskmanager.failure.perc"  = ( taskHistory.recordCount ? ( ( historicFailures  / taskHistory.recordCount ) * 100 ) : 0 )
			, "taskmanager.success.perc"  = ( taskHistory.recordCount ? ( ( historicSuccesses / taskHistory.recordCount ) * 100 ) : 0 )
			, "taskmanager.total.time"    = totalTime
			, "taskmanager.avg.time"      = ( taskHistory.recordCount ? ( totalTime / taskHistory.recordCount ) : 0 )
		};
	}

// PRIVATE HELPERS
	private any function _createJodaTimeObject( required date cfmlDateTime ) {
		return CreateObject( "java", "org.joda.time.DateTime", "/preside/system/services/taskmanager/lib/cron-1.0.jar" ).init( cfmlDateTime );
	}

	private any function _getCrontabExpressionObject( required string expression ) {
		return CreateObject( "java", "fc.cron.CronExpression", "/preside/system/services/taskmanager/lib/cron-1.0.jar" ).init( arguments.expression );
	}

	private void function _initialiseDb() {
		ensureTasksExistInStatusDb();
	}

	private date function _getOperationDate() {
		return Now();
	}

	private string function _cronTabExpressionToHuman( required string expression ) {
		return CreateObject( "java", "net.redhogs.cronparser.CronExpressionDescriptor", [ "/preside/system/services/taskmanager/lib/cron-parser-2.6-SNAPSHOT.jar", "/preside/system/services/taskmanager/lib/commons-lang3-3.3.2.jar" ] ).getDescription( arguments.expression );
	}

	private string function _getScheduledTaskUrl( required string siteId ) {
		var siteSvc    = _getSiteService();
		var site       = siteSvc.getSite( Len( Trim( arguments.siteId ) ) ? arguments.siteId : siteSvc.getActiveSiteId() );
		var serverName = ( site.domain ?: cgi.server_name );

		return "http://" & serverName & "/taskmanager/runtasks/";
	}

// GETTERS AND SETTERS
	private struct function _getConfiguredTasks() {
		return _configuredTasks;
	}
	private void function _setConfiguredTasks( required struct configuredTasks ) {
		_configuredTasks = arguments.configuredTasks;
	}

	private any function _getController() {
		return _controller;
	}
	private void function _setController( required any controller ) {
		_controller = arguments.controller;
	}

	private any function _getTaskDao() {
		return _taskDao;
	}
	private void function _setTaskDao( required any taskDao ) {
		_taskDao = arguments.taskDao;
	}

	private any function _getTaskHistoryDao() {
		return _taskHistoryDao;
	}
	private void function _setTaskHistoryDao( required any taskHistoryDao ) {
		_taskHistoryDao = arguments.taskHistoryDao;
	}

	private any function _getSystemConfigurationService() {
		return _systemConfigurationService;
	}
	private void function _setSystemConfigurationService( required any systemConfigurationService ) {
		_systemConfigurationService = arguments.systemConfigurationService;
	}

	private any function _getCfThreadHelper() {
		return _cfThreadHelper;
	}
	private void function _setCfThreadHelper( required any cfThreadHelper ) {
		_cfThreadHelper = arguments.cfThreadHelper;
	}

	private any function _getLogger( string logId="", string taskKey="" ) {
		var taskRunId = Len( Trim( arguments.logId ) ) ? arguments.logId : getActiveHistoryIdForTask( arguments.taskKey );

		return new TaskManagerLoggerWrapper(
			  logboxLogger   = _logger
			, taskRunId      = taskRunId
			, taskHistoryDao = _getTaskHistoryDao()
		);
	}
	private void function _setLogger( required any logger ) {
		_logger = arguments.logger;
	}

	private any function _getErrorLogService() {
		return _errorLogService;
	}
	private void function _setErrorLogService( required any errorLogService ) {
		_errorLogService = arguments.errorLogService;
	}

	private any function _getSiteService() {
		return _siteService;
	}
	private void function _setSiteService( required any siteService ) {
		_siteService = arguments.siteService;
	}

}