package dev.firezone.android.features.onboarding.domain

internal class ValidateInputUseCase {
    operator fun invoke(input: String): InputError =
        InputError().apply {
            isErrorEnabled = input.isEmpty()
        }
}
