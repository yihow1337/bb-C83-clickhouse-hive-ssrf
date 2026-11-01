    }
    catch (const std::invalid_argument&)
    {
        throw DB::Exception(DB::ErrorCodes::DATALAKE_DATABASE_ERROR, "Invalid port number: '{}'", port_str);
    }
}

}

HiveCatalog::HiveCatalog(const std::string & warehouse_, const std::string & base_url_, DB::ContextPtr context_)
    : ICatalog(warehouse_)
    , DB::WithContext(context_)
    , base_url(base_url_)
{
    std::lock_guard lock(client_mutex);
    reconnectUnlocked();
}

void HiveCatalog::reconnectUnlocked() const TSA_REQUIRES(client_mutex)
{
    if (transport && transport->isOpen())
    {
        try
        {
            transport->close();
        }
        catch (const std::exception & ex)
        {
            LOG_TRACE(&Poco::Logger::get("HiveCatalog"), "Error closing transport: {}", ex.what());
        }
    }

    auto [host, port] = parseHostPort(base_url);

    /// Also rejects control characters such as NUL, which `getaddrinfo` would truncate the host at.
    getContext()->getRemoteHostFilter().checkAndGetCanonicalHostAndPort(
        host + ":" + std::to_string(port), static_cast<UInt16>(port), "Hive metastore address");

    socket = std::make_shared<apache::thrift::transport::TSocket>(host, port);
    transport = std::make_shared<apache::thrift::transport::TBufferedTransport>(socket);
    protocol = std::make_shared<apache::thrift::protocol::TBinaryProtocol>(transport);
    client = std::make_unique<Apache::Hadoop::Hive::ThriftHiveMetastoreClient>(protocol);

    transport->open();
}

template <typename Func>
void HiveCatalog::executeWithRetry(Func && func) const
{
    constexpr int max_retries = 3;
    String last_err_msg;

    for (int i = 0; i < max_retries; ++i)
    {
        std::unique_lock lock(client_mutex);

        try
        {
            func();
            return;
        }
        catch (apache::thrift::transport::TTransportException & e)
        {
            last_err_msg = e.what();

            try
            {
                reconnectUnlocked();
            }
            catch (const DB::Exception &)
            {
                /// Non-transient (e.g. `UNACCEPTABLE_URL` from `remote_url_allow_hosts`), retrying cannot help.
                throw;
            }
            catch (const std::exception & ex)
            {
                LOG_TRACE(
                    &Poco::Logger::get("HiveCatalog"), "Reconnect failed in iteration {}/{} with error: {}", i, max_retries, ex.what());
            }
        }
    }
