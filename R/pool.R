setClass('Connection')

mPool <- setRefClass('Pool',
	fields = list(
		server = 'Connection',
		port = 'integer', # for informational purposes only
		clients = 'list', # actually list<ClientConnection>
		nodes = 'list',   # actually list<NodeConnection>
		tasks = 'list'    # actually list<Task>
		# actually would like them to be mutable
	),
	methods = list(
		initialize = function(port) {
			stopifnot(
				is.numeric(port), length(port) == 1, port == round(port),
				port > 0, port < 65536
			)
			.self$port <- as.integer(port)
			.self$server <- mServerConnection(
				socket = serverSocket(.self$port),
				pool = .self
			)

			.self$clients <- list()
			.self$nodes <- list()
			.self$tasks <- list()
		},
		show = function() cat(
			'<Pool(port=', port, '): ',
			length(clients), ' client(s), ',
			length(nodes),   ' node(s), ',
			length(tasks), ' task(s)',
			'>\n', sep = ''
		),
		process_one_event = function() {
			connections <- c(list(server), clients, nodes)
			to_write <- vapply(connections, function(s) s$need_write(), FALSE)
			sockets <- lapply(connections, function(s) s$socket)
			idx <- which.max(socketSelect(sockets, to_write))
			connections[[idx]]$process_event()
		},
		add_connection = function(client) {
			# Connections start out as clients and may later transition
			# to being nodes if they send a special message.
			.self$clients <- c(clients, list(client))
		},
		remove_node = function(node) {
			node$finalize() # explicitly clean up right away
			# If was working on a task, must give it to a different node
			if (!is.null(node$task))
				.self$tasks <- c(tasks, list(node$task))
			keep <- !vapply(nodes, identical, FALSE, node)
			.self$nodes <- nodes[keep]
		},
		remove_client = function(client) {
			client$finalize()
			# Remove the client's tasks
			keep <- !vapply(tasks, function(task) identical(task$client, client), FALSE)
			.self$tasks <- tasks[keep]
			# Remove the client
			keep <- !vapply(clients, identical, FALSE, client)
			.self$clients <- clients[keep]
		},
		add_task = function(task) {
			.self$tasks <- c(tasks, list(task))
		},
		pop_task = function() {
			stopifnot(length(tasks) > 0)
			ret <- tasks[[1]]
			.self$tasks <- tasks[-1]
			ret
		},
		make_node = function(client) {
			sock <- client$socket
			client$socket <- NULL
			remove_client(client)
			.self$nodes <- c(nodes, list(mNodeConnection(sock, .self)))
		}
	)
)
mPool$lock(c('port', 'server'))

setOldClass(c('servsockconn', 'sockconn'))
setClassUnion('optional_sockconn', c('servsockconn', 'sockconn', 'NULL'))
setClassUnion('optional_Pool', c('Pool', 'NULL'))
setRefClass('ConnectionBase',
	fields = list(
		socket = 'optional_sockconn',
		pool = 'optional_Pool'
	),
	contains = c('Connection', 'VIRTUAL'),
	methods = list(
		# We're more or less guaranteed to be called with an empty
		# argument list, so we have to allow empty Connection objects
		# (socket = NULL), even if they are otherwise useless.
		initialize = function(socket = NULL, pool = NULL) {
			stopifnot(missing(socket) == missing(pool))
			.self$socket <- socket
			.self$pool <- pool
		},
		finalize = function() if (!is.null(socket)) {
			close(socket)
			.self$socket <- NULL
		},
		# Used for select().
		need_write = function() FALSE
		# Subclasses *must* define a process_event() method that would
		# obtain the event however it can and call the referenced Pool
		# object to handle it. It will be called if socketSelect()
		# returns the corresponding socket as available.
	)
)

mServerConnection <- setRefClass('ServerConnection',
	contains = 'ConnectionBase',
	methods = list(
		process_event = function()
			pool$add_connection(mClientConnection(
				socketAccept(socket, open = 'a+b'), pool
			))
	)
)

mClientConnection <- setRefClass('ClientConnection',
	fields = list(
		# Data to be sent to the other side of the connection.
		# To be used for already computed tasks.
		results = 'list'
	),
	contains = 'ConnectionBase',
	methods = list(
		# Write completed tasks back to the client; otherwise ask for
		# more.
		need_write = function() length(results) > 0,
		process_event = function() tryCatch(
			if (need_write()) {
				serialize(results[[1]], socket)
				# pop *after* a successful write, not before
				.self$results <- results[-1]
			} else {
				msg <- unserialize(socket)
				switch(msg$type,
					EXEC = pool$add_task(mTask(
						client = .self,
						tag = msg$data$tag,
						payload = msg
					)),
					NODE = {
						pool$make_node(.self)
					}
					# TODO: accept serialize() version
				)
			},
			# sockets being closed will typically become "readable" and
			# then fail to read
			error = function(e) pool$remove_client(.self)
		),
		add_result = function(payload) {
			.self$results = c(results, list(payload))
		}
	)
)

mTask <- setRefClass('Task',
	fields = list(
		client = 'ClientConnection',
		tag = 'ANY',
		payload = 'ANY'
	)
)
setClassUnion('optional_Task', c('Task', 'NULL'))

mNodeConnection <- setRefClass('NodeConnection',
	fields = list(
		task = 'optional_Task'
	),
	contains = 'ConnectionBase',
	methods = list(
		# If a node has a pending task, we're waiting for it to send the
		# task result back to us.
		# If the queue is not empty, we need to submit new jobs.
		# Otherwise, let's default to readable (we have nothing to
		# write).
		need_write = function()
			if (!is.null(task)) FALSE else length(pool$tasks) > 0,
		process_event = function() tryCatch(
			if (need_write()) {
				.self$task <- pool$pop_task()
				serialize(task$payload, socket)
			} else {
				msg <- unserialize(socket)
				switch(msg$type,
					VALUE = {
						msg$tag <- task$tag
						task$client$add_result(msg)
					}
				)
				.self$task <- NULL
			},
			error = function(e) pool$remove_node(.self)
		)
	)
)

run_pool <- function(port) {
	p <- mPool(port)
	repeat p$process_one_event()
}
