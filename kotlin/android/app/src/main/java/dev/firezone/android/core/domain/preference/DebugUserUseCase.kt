package dev.firezone.android.core.domain.preference

import dev.firezone.android.core.data.PreferenceRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flowOf

internal class DebugUserUseCase @Inject constructor(
    private val repository: PreferenceRepository
) {
    suspend operator fun invoke(): Flow<Unit> {
        repository.savePortalUrl("https://app.firezone.dev/team-id/").collect()
        repository.saveJWT("eyJ0eXAiOiJhdCtqd3QiLCJhbGciOiJSUzI1NiIsImtpZCI6IjFMN3k3RUM1T3VSZUNNNnIzX2l0MXNJbjNqeTdiZ2JPSVB3Z0xoejV0SGsifQ.eyJpc3MiOiJodHRwczovL2ZpcmV6b25lLmxvY2FsIiwic3ViIjoidGVzdEBmaXJlem9uZS5kZXYiLCJjbGllbnRfaWQiOiJmaXJlem9uZSIsImV4cCI6MTY3MjgzNzU0NCwiaWF0IjoxNjY4MTMzOTQ0fQ.NvvGWvrMvshKp5MYycDWXa8gQ41Ptrr_nIKzfPWzci8fxwmQYJ5hL1vQpdmECtR5NeGv7qTavi6yq19Kqmwrn27numDXaET2b2xypGbFOm1TJmcbZ4Rxy_-FfAeer-7YNhW_p83a0N7UoPORpxVs8hp76sKe_klfmoM830frrLzeqz0VYxBZXhPiTAlqiG39cY74yk-drxLY4xeRBAXh_TdewrkRkPpTpsrXFz60fF5P8AaRnUKlDSRq89ZIC-zo2ysJsXIZLrJpfcNgkscohZZfXfCLIFaiGvZseW0XHWfq-V5HOXVf09-57GHdmCr-AAJ7sqpnPrSBvg7EDBvylg").collect()
        return flowOf ()
    }
}
