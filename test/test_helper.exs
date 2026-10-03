# The console's crash reports are noise here; the console test adds its own.
:logger.remove_handler(:default)

# ExUnit sets backtrace_depth to 20 after Blackbox set 32 (04-34).
:erlang.system_flag(:backtrace_depth, 32)

# A fresh database with Blackbox's tables, through the generated-migration path.
repo = Blackbox.TestRepo
config = repo.config()
_ = Ecto.Adapters.Postgres.storage_down(config)
:ok = Ecto.Adapters.Postgres.storage_up(config)
{:ok, _} = repo.start_link()
Ecto.Migrator.up(repo, 1, Blackbox.TestRepo.Migration, log: false)

ExUnit.start(exclude: [:flood], max_cases: 1)
