import { delay } from 'redux-saga';
import { call, cancel, fork, put, select, take, takeLatest, takeEvery } from 'redux-saga/effects';

import { pageRequestIndicator } from 'src/misc/pageRequestIndicator';
import {
  CLUSTER_PAGE_DID_MOUNT,
  CLUSTER_PAGE_DATA_REQUEST,
  CLUSTER_PAGE_DATA_REQUEST_SUCCESS,
  CLUSTER_PAGE_DATA_REQUEST_ERROR,
  CLUSTER_PAGE_REFRESH_LISTS_REQUEST,
  CLUSTER_PAGE_REFRESH_LISTS_REQUEST_SUCCESS,
  CLUSTER_PAGE_REFRESH_LISTS_REQUEST_ERROR,
  CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST,
  CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST_SUCCESS,
  CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST_ERROR,
  CLUSTER_PAGE_PROBE_SERVER_REQUEST,
  CLUSTER_PAGE_PROBE_SERVER_REQUEST_SUCCESS,
  CLUSTER_PAGE_PROBE_SERVER_REQUEST_ERROR,
  CLUSTER_PAGE_JOIN_SERVER_REQUEST,
  CLUSTER_PAGE_JOIN_SERVER_REQUEST_SUCCESS,
  CLUSTER_PAGE_JOIN_SERVER_REQUEST_ERROR,
  CLUSTER_PAGE_CREATE_REPLICASET_REQUEST,
  CLUSTER_PAGE_CREATE_REPLICASET_REQUEST_SUCCESS,
  CLUSTER_PAGE_CREATE_REPLICASET_REQUEST_ERROR,
  CLUSTER_PAGE_EXPEL_SERVER_REQUEST,
  CLUSTER_PAGE_EXPEL_SERVER_REQUEST_SUCCESS,
  CLUSTER_PAGE_EXPEL_SERVER_REQUEST_ERROR,
  CLUSTER_PAGE_REPLICASET_EDIT_REQUEST,
  CLUSTER_PAGE_REPLICASET_EDIT_REQUEST_SUCCESS,
  CLUSTER_PAGE_REPLICASET_EDIT_REQUEST_ERROR,
  CLUSTER_PAGE_UPLOAD_CONFIG_REQUEST,
  CLUSTER_PAGE_UPLOAD_CONFIG_REQUEST_SUCCESS,
  CLUSTER_PAGE_UPLOAD_CONFIG_REQUEST_ERROR,
  CLUSTER_PAGE_APPLY_TEST_CONFIG_REQUEST,
  CLUSTER_PAGE_APPLY_TEST_CONFIG_REQUEST_SUCCESS,
  CLUSTER_PAGE_APPLY_TEST_CONFIG_REQUEST_ERROR,
  CLUSTER_PAGE_FAILOVER_CHANGE_REQUEST,
  CLUSTER_PAGE_FAILOVER_CHANGE_REQUEST_SUCCESS,
  CLUSTER_PAGE_FAILOVER_CHANGE_REQUEST_ERROR,
  CLUSTER_PAGE_DISABLE_SERVERS_REQUEST,
  CLUSTER_PAGE_DISABLE_SERVERS_REQUEST_SUCCESS,
  CLUSTER_PAGE_DISABLE_SERVERS_REQUEST_ERROR,
  CLUSTER_PAGE_STATE_RESET,
  CLUSTER_SELF_UPDATE,
} from 'src/store/actionTypes';
import { baseSaga, getRequestSaga, getSignalRequestSaga } from 'src/store/commonRequest';
import { getClusterSelf } from 'src/store/request/app.requests';
import {
  getPageData, refreshLists, getServerStat, bootstrapVshard, probeServer, joinServer, createReplicaset,
  expelServer, editReplicaset, joinSingleServer, uploadConfig, applyTestConfig, changeFailover, disableServers
} from 'src/store/request/clusterPage.requests';
import { REFRESH_LIST_INTERVAL } from 'src/constants';

const STAT_REQUEST_PERIOD = 10;

const pageDataRequestSaga = getSignalRequestSaga(
  CLUSTER_PAGE_DID_MOUNT,
  CLUSTER_PAGE_DATA_REQUEST,
  CLUSTER_PAGE_DATA_REQUEST_SUCCESS,
  CLUSTER_PAGE_DATA_REQUEST_ERROR,
  getPageData,
);

function* refreshListsTaskSaga() {
  let requestNum = 0;

  while (true) {
    yield delay(REFRESH_LIST_INTERVAL);
    yield put({ type: CLUSTER_PAGE_REFRESH_LISTS_REQUEST });

    let response;
    try {
      const shouldRequestStat = ++requestNum % STAT_REQUEST_PERIOD === 0;
      if (shouldRequestStat) {
        response = yield call(refreshLists, { shouldRequestStat: true });
      }
      else {
        const listsResponse = yield call(refreshLists);

        let serverStatResponse;
        const serverStat = yield select(state => state.clusterPage.serverStat);
        const unknownServerExists = listsResponse.serverList
          .some(server => server.replicaset && !serverStat.find(stat => stat.uuid === server.uuid));
        if (unknownServerExists) {
          serverStatResponse = yield call(getServerStat);
        }

        response = {
          ...listsResponse,
          ...serverStatResponse,
        };
      }
    }
    catch (error) {
      yield put({ type: CLUSTER_PAGE_REFRESH_LISTS_REQUEST_ERROR, error, requestPayload: {} });
    }
    if (response) {
      if (response.serverStat) {
        response = {
          ...response,
          serverStat: response.serverStat.filter(stat => stat.uuid),
        };
      }
      yield put({ type: CLUSTER_PAGE_REFRESH_LISTS_REQUEST_SUCCESS, payload: response, requestPayload: {} });
    }
  }
}

function* refreshListsRequestSaga() {
  while (true) {
    yield take(CLUSTER_PAGE_DATA_REQUEST_SUCCESS);
    const refreshListsTask = yield fork(refreshListsTaskSaga);
    yield take(CLUSTER_PAGE_STATE_RESET);
    yield cancel(refreshListsTask);
  }
}

const bootstrapVshardRequestSaga = getRequestSaga(
  CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST,
  CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST_SUCCESS,
  CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST_ERROR,
  bootstrapVshard,
);

const probeServerRequestSaga = getRequestSaga(
  CLUSTER_PAGE_PROBE_SERVER_REQUEST,
  CLUSTER_PAGE_PROBE_SERVER_REQUEST_SUCCESS,
  CLUSTER_PAGE_PROBE_SERVER_REQUEST_ERROR,
  probeServer,
);

const joinServerRequestSaga = getRequestSaga(
  CLUSTER_PAGE_JOIN_SERVER_REQUEST,
  CLUSTER_PAGE_JOIN_SERVER_REQUEST_SUCCESS,
  CLUSTER_PAGE_JOIN_SERVER_REQUEST_ERROR,
  joinServer,
);

function* createReplicasetRequestSaga() {
  yield takeLatest(CLUSTER_PAGE_CREATE_REPLICASET_REQUEST, function* load(action) {
    const { payload: requestPayload = {} } = action;
    const indicator = pageRequestIndicator.run();

    let response;
    try {
      const createReplicasetResponse = yield call(createReplicaset, requestPayload);
      indicator.next();
      const clusterSelfResponse = yield call(getClusterSelf);
      indicator.success();

      response = {
        ...createReplicasetResponse,
        ...clusterSelfResponse,
      };
    }
    catch (error) {
      yield put({ type: CLUSTER_PAGE_CREATE_REPLICASET_REQUEST_ERROR, error, requestPayload });
      indicator.error();
      return;
    }

    yield put({ type: CLUSTER_PAGE_CREATE_REPLICASET_REQUEST_SUCCESS, payload: response, requestPayload });
  });
}

const expelServerRequestSaga = getRequestSaga(
  CLUSTER_PAGE_EXPEL_SERVER_REQUEST,
  CLUSTER_PAGE_EXPEL_SERVER_REQUEST_SUCCESS,
  CLUSTER_PAGE_EXPEL_SERVER_REQUEST_ERROR,
  expelServer,
);

const editReplicasetRequestSaga = getRequestSaga(
  CLUSTER_PAGE_REPLICASET_EDIT_REQUEST,
  CLUSTER_PAGE_REPLICASET_EDIT_REQUEST_SUCCESS,
  CLUSTER_PAGE_REPLICASET_EDIT_REQUEST_ERROR,
  editReplicaset,
);

const uploadConfigRequestSaga = getRequestSaga(
  CLUSTER_PAGE_UPLOAD_CONFIG_REQUEST,
  CLUSTER_PAGE_UPLOAD_CONFIG_REQUEST_SUCCESS,
  CLUSTER_PAGE_UPLOAD_CONFIG_REQUEST_ERROR,
  uploadConfig,
);

function* applyTestConfigRequestSaga() {
  yield takeLatest(CLUSTER_PAGE_APPLY_TEST_CONFIG_REQUEST, function* load(action) {
    const { payload: requestPayload = {} } = action;
    const indicator = pageRequestIndicator.run();

    let response;
    try {
      yield call(joinSingleServer, requestPayload);
      indicator.next();
      response = yield call(applyTestConfig);
      indicator.success();
    }
    catch (error) {
      yield put({ type: CLUSTER_PAGE_APPLY_TEST_CONFIG_REQUEST_ERROR, error, requestPayload });
      indicator.error();
      return;
    }

    yield put({ type: CLUSTER_PAGE_APPLY_TEST_CONFIG_REQUEST_SUCCESS, payload: response, requestPayload });
  });
}

const changeFailoverRequestSaga = getRequestSaga(
  CLUSTER_PAGE_FAILOVER_CHANGE_REQUEST,
  CLUSTER_PAGE_FAILOVER_CHANGE_REQUEST_SUCCESS,
  CLUSTER_PAGE_FAILOVER_CHANGE_REQUEST_ERROR,
  changeFailover,
);

const disableServersRequestSaga = getRequestSaga(
  CLUSTER_PAGE_DISABLE_SERVERS_REQUEST,
  CLUSTER_PAGE_DISABLE_SERVERS_REQUEST_SUCCESS,
  CLUSTER_PAGE_DISABLE_SERVERS_REQUEST_ERROR,
  disableServers,
);

const updateClusterSelfOnBootstrap = function* () {
  yield takeEvery(CLUSTER_PAGE_BOOTSTRAP_VSHARD_REQUEST_SUCCESS, function* () {
    while (true) {
      try {
        const clusterSelfResponse = yield call(getClusterSelf);
        yield put({ type: CLUSTER_SELF_UPDATE, payload: clusterSelfResponse });
        return;
      } catch (e) {
        yield delay(2000);
      }
    }
  })
}

export const saga = baseSaga(
  pageDataRequestSaga,
  refreshListsRequestSaga,
  bootstrapVshardRequestSaga,
  probeServerRequestSaga,
  joinServerRequestSaga,
  createReplicasetRequestSaga,
  expelServerRequestSaga,
  editReplicasetRequestSaga,
  uploadConfigRequestSaga,
  applyTestConfigRequestSaga,
  changeFailoverRequestSaga,
  disableServersRequestSaga,
  updateClusterSelfOnBootstrap,
);
