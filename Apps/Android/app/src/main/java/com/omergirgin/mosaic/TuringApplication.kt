package com.omergirgin.mosaic

import android.app.Application
import com.omergirgin.mosaic.data.DataContainer
import com.omergirgin.mosaic.data.api.AppContainer
import com.omergirgin.mosaic.ui.tasks.installAutomationForegroundSweep

class TuringApplication : Application() {
  val container: AppContainer by lazy { DataContainer.create(this) }

  override fun onCreate() {
    super.onCreate()
    // Scheduled prompts: 30-second due sweep while the app is visible (container stays lazy).
    // WorkManager uses its default initializer; workers reach the same container singleton.
    installAutomationForegroundSweep { container.tasks }
  }
}
