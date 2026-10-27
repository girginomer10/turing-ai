package com.omergirgin.mosaic.data.repo

import com.omergirgin.mosaic.data.api.ProjectRepository
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.ProjectEntity
import com.omergirgin.mosaic.data.db.toModel
import com.omergirgin.mosaic.data.internal.FieldLimits
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.Project
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

internal class ProjectRepositoryImpl(private val db: MosaicDatabase) : ProjectRepository {
  private val dao = db.projects()

  override fun observeProjects(includeArchived: Boolean): Flow<List<Project>> =
    dao.observeAll(includeArchived).map { rows -> rows.map { it.toModel() } }.distinctUntilChanged()

  override fun observeProject(id: String): Flow<Project?> =
    dao.observe(id).map { it?.toModel() }.distinctUntilChanged()

  override suspend fun saveProject(id: String?, name: String, instructions: String, defaultModel: ModelChoice?): Project {
    val trimmedName = name.trim()
    require(trimmedName.isNotEmpty()) { "Enter a project name." }
    FieldLimits.requireWithin(trimmedName, FieldLimits.PROJECT_NAME_BYTES, "The project name")
    FieldLimits.requireWithin(instructions, FieldLimits.PROJECT_INSTRUCTIONS_BYTES, "The project instructions")

    val existing = id?.let { dao.get(it) }
    require(id == null || existing != null) { "This project no longer exists." }
    val now = MonotonicClock.now()
    val entity = ProjectEntity(
      id = existing?.id ?: newId(),
      name = trimmedName,
      instructions = instructions,
      isArchived = existing?.isArchived ?: false,
      defaultProviderId = defaultModel?.providerId,
      defaultModelId = defaultModel?.modelId,
      createdAt = existing?.createdAt ?: now,
      updatedAt = now,
    )
    dao.upsert(entity)
    return entity.toModel()
  }

  override suspend fun setArchived(id: String, archived: Boolean) {
    dao.setArchived(id, archived, MonotonicClock.now())
  }

  /**
   * Chats in the project are kept and move back to the personal workspace (foreign key SET NULL);
   * project-scoped pinned facts are deleted with it because they have no audience left. iOS has
   * no project deletion (archive only), so the UI should confirm this explicitly.
   */
  override suspend fun delete(id: String) {
    dao.delete(id)
  }
}
