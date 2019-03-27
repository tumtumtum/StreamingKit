//
//  STKSpinLock.h
//  StreamingKit
//
//  Created by Diego Stamigni on 20/03/2019.
//  Copyright © 2019 Thong Nguyen. All rights reserved.
//

#pragma once

#import "STKMacro.h"
#include <dlfcn.h>

#if BASE_SDK_HIGHER_THAN_10
#import <os/lock.h>
#else
#define OS_UNFAIR_LOCK_INIT ((os_unfair_lock){0})

typedef struct _os_unfair_lock_s {
    uint32_t _os_unfair_lock_opaque;
} os_unfair_lock, *os_unfair_lock_t;
#endif

#if !DEPLOYMENT_TARGET_HIGHER_THAN_10
#import <libkern/OSAtomic.h>
#endif

static void setLock(os_unfair_lock *lock)
{
#if DEPLOYMENT_TARGET_HIGHER_THAN_10
    os_unfair_lock_lock(lock);
#else
    if (DEVICE_HIGHER_THAN_10)
    {
        void (*os_unfair_lock_lock)(void *lock) = dlsym(dlopen(NULL, RTLD_NOW | RTLD_GLOBAL), "os_unfair_lock_lock");
        if (os_unfair_lock_lock != NULL)
        {
            os_unfair_lock_lock(lock);
            return;
        }
    }

    #pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    OSSpinLockLock((void *)lock);
#endif
}

static void lockUnlock(os_unfair_lock *lock)
{
#if DEPLOYMENT_TARGET_HIGHER_THAN_10
    os_unfair_lock_unlock(lock);
#else
    if (DEVICE_HIGHER_THAN_10)
    {
        void (*os_unfair_lock_unlock)(void *lock) = dlsym(dlopen(NULL, RTLD_NOW | RTLD_GLOBAL), "os_unfair_lock_unlock");
        if (os_unfair_lock_unlock != NULL)
        {
            os_unfair_lock_unlock(lock);
            return;
        }
    }

    #pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    OSSpinLockUnlock((void *)lock);
#endif
}

