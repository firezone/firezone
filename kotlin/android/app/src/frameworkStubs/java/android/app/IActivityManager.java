package android.app;

import android.os.IBinder;
import android.os.IInterface;
import android.os.RemoteException;

public interface IActivityManager extends IInterface {
    ContentProviderHolder getContentProviderExternal(String name, int userId, IBinder token, String tag)
            throws RemoteException;

    void removeContentProviderExternalAsUser(String name, IBinder token, int userId) throws RemoteException;
}
