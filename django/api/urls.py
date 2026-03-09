from django.urls import path
from . import views

urlpatterns = [
    path('health',         views.HealthView.as_view()),
    path('auth/login',     views.LoginView.as_view()),
    path('auth/refresh',   views.TokenRefreshView.as_view()),
    path('auth/logout',    views.LogoutView.as_view()),
    path('test',           views.TestView.as_view()),
]